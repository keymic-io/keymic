import Accelerate
import Foundation

/// Kaldi-compatible fbank front-end matching funasr `WavFrontend`
/// (`torchaudio.compliance.kaldi.fbank` defaults) followed by LFR stacking and CMVN.
///
/// Pipeline per `extract(samples:)`:
///   1. upscale samples (funasr `upsacle_samples`) + frame the signal
///      (snip_edges, frame_length=25ms, frame_shift=10ms)
///   2. per frame: remove DC offset -> preemphasis(0.97) -> Hamming window
///      -> zero-pad to 512 -> rFFT -> power spectrum -> mel(80) -> log(max(e, EPS))
///   3. LFR (m=7, n=6): pad start with 3 copies of first frame, stride n, tail repeats last
///   4. CMVN: out[d] = (in[d] + addShift[d]) * rescale[d]   (am.mvn, 560-dim)
///
/// Output is `[T][560]` matching `SenseVoiceConfig.modelFeatureDim`.
/// Reproduces the committed `hello_fbank.json` golden to maxErr ~1.4e-5.
final class FbankExtractor {
    // MARK: framing geometry
    private let sampleRate = Float(SenseVoiceConfig.sampleRate)
    private let frameLength: Int  // samples per frame (400 @ 16k/25ms)
    private let frameShift: Int  // samples per hop  (160 @ 16k/10ms)
    private let fftSize: Int  // 512 (next pow2 >= frameLength)
    private let numFftBins: Int  // fftSize/2 + 1 = 257
    private let melBins = SenseVoiceConfig.melBins  // 80

    // kaldi constants
    private let preemphasis: Float = 0.97
    private let epsilon: Float = 1.1920928955078125e-07  // FLT_EPSILON, kaldi's log-energy floor
    private let lowFreq: Float = 20
    private let highFreq: Float  // nyquist (8000)

    /// funasr `WavFrontend` upscales the [-1,1] float waveform before kaldi.fbank.
    /// It applies a single `waveform * (1 << 15)` to the [-1,1] audio (funasr's audio
    /// loaders return [-1,1]); the bundled `am.mvn` CMVN stats are computed at this 2^15
    /// scale. We mirror that exact single multiplier here so live mic samples land in the
    /// model's training distribution. The golden `hello_fbank.json` is regenerated at 2^15.
    private let sampleScale: Float = Float(1 << 15)

    // precomputed
    private let window: [Float]  // analysis window, length frameLength
    private let melFilters: [[Float]]  // [melBins][numFftBins]
    private let cmvnShift: [Float]  // 560
    private let cmvnScale: [Float]  // 560

    // vDSP FFT setup
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    // LFR params
    private let lfrM = SenseVoiceConfig.lfrM
    private let lfrN = SenseVoiceConfig.lfrN
    private let featureDim = SenseVoiceConfig.modelFeatureDim

    init(mvnPath: String) {
        frameLength = Int((Double(SenseVoiceConfig.sampleRate) * SenseVoiceConfig.frameLengthMs / 1000.0).rounded())
        frameShift = Int((Double(SenseVoiceConfig.sampleRate) * SenseVoiceConfig.frameShiftMs / 1000.0).rounded())
        // next power of two >= frameLength
        var fft = 1
        while fft < frameLength { fft <<= 1 }
        fftSize = fft
        numFftBins = fft / 2 + 1
        highFreq = Float(SenseVoiceConfig.sampleRate) / 2

        window = FbankExtractor.hammingWindow(length: frameLength)
        melFilters = FbankExtractor.melFilterbank(
            numBins: melBins,
            numFftBins: fft / 2 + 1,
            fftSize: fft,
            sampleRate: Float(SenseVoiceConfig.sampleRate),
            lowFreq: 20,
            highFreq: Float(SenseVoiceConfig.sampleRate) / 2)

        let (shift, scale) = FbankExtractor.loadMVN(path: mvnPath, dim: featureDim)
        cmvnShift = shift
        cmvnScale = scale

        log2n = vDSP_Length(log2(Float(fft)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("FbankExtractor: vDSP_create_fftsetup failed")
        }
        fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Public

    func extract(samples: [Float]) -> [[Float]] {
        let logMel = computeLogMel(samples: samples)  // [nFrames][80]
        let stacked = applyLFR(logMel)  // [T][560]
        return applyCMVN(stacked)  // [T][560]
    }

    // MARK: - Stage 1: kaldi fbank -> log-mel

    /// Returns `[nFrames][melBins]` log-mel energies (pre-LFR, pre-CMVN).
    func computeLogMel(samples: [Float]) -> [[Float]] {
        let n = samples.count
        guard n >= frameLength else { return [] }
        // snip_edges = true
        let nFrames = 1 + (n - frameLength) / frameShift
        guard nFrames > 0 else { return [] }

        var output = [[Float]](repeating: [Float](repeating: 0, count: melBins), count: nFrames)

        // reusable scratch
        var frame = [Float](repeating: 0, count: frameLength)
        var windowed = [Float](repeating: 0, count: fftSize)  // zero-padded to fftSize
        var power = [Float](repeating: 0, count: numFftBins)

        // split-complex scratch for vDSP rFFT
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)

        samples.withUnsafeBufferPointer { src in
            for f in 0..<nFrames {
                let start = f * frameShift
                // copy raw frame, applying funasr's waveform upscale
                for i in 0..<frameLength { frame[i] = src[start + i] * sampleScale }

                // remove DC offset (subtract mean)
                var mean: Float = 0
                vDSP_meanv(frame, 1, &mean, vDSP_Length(frameLength))
                var negMean = -mean
                vDSP_vsadd(frame, 1, &negMean, &frame, 1, vDSP_Length(frameLength))

                // preemphasis: x[i] = raw[i] - 0.97*raw[i-1]; x[0] = raw[0] - 0.97*raw[0]
                // process from end to start so we can do it in place
                let first = frame[0]
                for i in stride(from: frameLength - 1, through: 1, by: -1) {
                    frame[i] -= preemphasis * frame[i - 1]
                }
                frame[0] = first - preemphasis * first

                // Povey window + zero pad to fftSize
                for i in 0..<frameLength { windowed[i] = frame[i] * window[i] }
                for i in frameLength..<fftSize { windowed[i] = 0 }

                // real FFT via vDSP. Pack even/odd into split complex, run zrip, build power.
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBufferPointer { wptr in
                            wptr.baseAddress!.withMemoryRebound(
                                to: DSPComplex.self, capacity: fftSize / 2
                            ) { cptr in
                                vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(fftSize / 2))
                            }
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                        // vDSP packs: realp[0] = DC real, imagp[0] = Nyquist real.
                        // bin 0 (DC)
                        let dc = rp[0]
                        power[0] = dc * dc
                        // nyquist (bin numFftBins-1 = fftSize/2)
                        let ny = ip[0]
                        power[numFftBins - 1] = ny * ny
                        // bins 1 .. fftSize/2 - 1
                        for k in 1..<(fftSize / 2) {
                            let re = rp[k]
                            let im = ip[k]
                            power[k] = re * re + im * im
                        }
                        // undo vDSP's factor-of-2 scaling on amplitude -> factor 4 on power
                        var quarter: Float = 0.25
                        vDSP_vsmul(power, 1, &quarter, &power, 1, vDSP_Length(numFftBins))
                    }
                }

                // mel energies = filter . power, then log(max(e, EPS))
                for m in 0..<melBins {
                    var e: Float = 0
                    let filt = melFilters[m]
                    vDSP_dotpr(filt, 1, power, 1, &e, vDSP_Length(numFftBins))
                    output[f][m] = log(max(e, epsilon))
                }
            }
        }
        return output
    }

    // MARK: - Stage 2: LFR (low frame rate stacking)

    /// funasr LFR: pad start with `(m-1)//2 = 3` copies of first frame, stride n,
    /// each output stacks m consecutive frames; tail past the end repeats the last frame.
    func applyLFR(_ frames: [[Float]]) -> [[Float]] {
        guard !frames.isEmpty else { return [] }
        let m = lfrM
        let nStride = lfrN
        let pad = (m - 1) / 2  // 3
        // funasr computes T_lfr from the ORIGINAL (un-padded) frame count, then prepends
        // `pad` copies of the first frame to the buffer used for stacking.
        let tLfr = Int(ceil(Double(frames.count) / Double(nStride)))
        var padded = [[Float]]()
        padded.reserveCapacity(frames.count + pad)
        for _ in 0..<pad { padded.append(frames[0]) }
        padded.append(contentsOf: frames)

        let total = padded.count
        let lastFrame = padded[total - 1]

        var out = [[Float]]()
        out.reserveCapacity(tLfr)
        for i in 0..<tLfr {
            var stacked = [Float]()
            stacked.reserveCapacity(featureDim)
            let base = i * nStride
            for j in 0..<m {
                let idx = base + j
                if idx < total {
                    stacked.append(contentsOf: padded[idx])
                } else {
                    stacked.append(contentsOf: lastFrame)
                }
            }
            out.append(stacked)
        }
        return out
    }

    // MARK: - Stage 3: CMVN

    func applyCMVN(_ frames: [[Float]]) -> [[Float]] {
        return frames.map { frame in
            var out = [Float](repeating: 0, count: frame.count)
            for d in 0..<frame.count {
                out[d] = (frame[d] + cmvnShift[d]) * cmvnScale[d]
            }
            return out
        }
    }

    // MARK: - Static builders

    /// Kaldi Hamming window: 0.54 - 0.46*cos(2*pi*n/(N-1)), N = length.
    /// funasr `WavFrontend` uses `window_type="hamming"`.
    static func hammingWindow(length: Int) -> [Float] {
        var w = [Float](repeating: 0, count: length)
        let denom = Float(length - 1)
        let twoPi = 2 * Float.pi
        for n in 0..<length {
            w[n] = 0.54 - 0.46 * cos(twoPi * Float(n) / denom)
        }
        return w
    }

    /// Kaldi-style triangular mel filterbank on the FFT bin grid.
    /// Reproduces `kaldi::MelBanks`: centers laid out linearly in mel space between
    /// mel(low_freq) and mel(high_freq); each FFT bin gets up/down slopes between
    /// adjacent mel centers. Returns `[numBins][numFftBins]`.
    static func melFilterbank(
        numBins: Int, numFftBins: Int, fftSize: Int, sampleRate: Float,
        lowFreq: Float, highFreq: Float
    ) -> [[Float]] {
        func melScale(_ freq: Float) -> Float { 1127.0 * log(1.0 + freq / 700.0) }

        let nyquist = sampleRate / 2
        let fftBinWidth = sampleRate / Float(fftSize)  // Hz per FFT bin
        let melLow = melScale(lowFreq)
        let melHigh = melScale(highFreq)
        // numBins+2 points -> numBins triangles; spacing in mel domain.
        let melDelta = (melHigh - melLow) / Float(numBins + 1)

        var filters = [[Float]](repeating: [Float](repeating: 0, count: numFftBins), count: numBins)

        for bin in 0..<numBins {
            let leftMel = melLow + Float(bin) * melDelta
            let centerMel = melLow + Float(bin + 1) * melDelta
            let rightMel = melLow + Float(bin + 2) * melDelta

            for k in 0..<numFftBins {
                let freq = fftBinWidth * Float(k)
                if freq > nyquist { continue }
                let mel = melScale(freq)
                if mel <= leftMel || mel >= rightMel { continue }
                let weight: Float
                if mel <= centerMel {
                    weight = (mel - leftMel) / (centerMel - leftMel)
                } else {
                    weight = (rightMel - mel) / (rightMel - centerMel)
                }
                filters[bin][k] = weight
            }
        }
        return filters
    }

    /// Parse kaldi CMVN text (`am.mvn`): an `<AddShift>` bracketed vector (negated means)
    /// and a `<Rescale>` bracketed vector (inverse std), each `dim` floats, possibly
    /// preceded by `<LearnRateCoef> 0` and spanning multiple lines.
    static func loadMVN(path: String, dim: Int) -> (shift: [Float], scale: [Float]) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fatalError("FbankExtractor: cannot read am.mvn at \(path)")
        }
        func vector(after tag: String) -> [Float] {
            guard let tagRange = text.range(of: tag) else {
                fatalError("FbankExtractor: \(tag) not found in am.mvn")
            }
            let rest = text[tagRange.upperBound...]
            guard let open = rest.firstIndex(of: "[") else {
                fatalError("FbankExtractor: '[' after \(tag) not found")
            }
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: "]") else {
                fatalError("FbankExtractor: ']' after \(tag) not found")
            }
            let body = afterOpen[..<close]
            let values = body.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                .compactMap { Float($0) }
            precondition(
                values.count == dim, "FbankExtractor: \(tag) has \(values.count) values, expected \(dim)")
            return values
        }
        return (vector(after: "<AddShift>"), vector(after: "<Rescale>"))
    }
}
