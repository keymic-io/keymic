import Foundation

@main
struct SecretScannerTestRunner {
    static func main() throws {
        let aws = SecretRule(raw: [
            "id": .string("aws-access-token"),
            "regex": .string(#"AKIA[0-9A-Z]{16}"#),
            "keywords": .array(["AKIA"]),
            "description": .string("AWS Access Key")
        ])!
        let openai = SecretRule(raw: [
            "id": .string("openai-api-key"),
            "regex": .string(#"sk-[A-Za-z0-9]{20,}"#),
            "keywords": .array(["sk-"]),
            "description": .string("OpenAI API Key")
        ])!
        let scanner = SecretScanner(rules: [aws, openai])

        let m1 = scanner.firstMatch(in: "deploy to AKIAABCDEFGHIJKLMNOP today")
        expect(m1?.rule.id == "aws-access-token", "aws match")
        expect(m1?.secret == "AKIAABCDEFGHIJKLMNOP", "extracted secret")

        let m2 = scanner.firstMatch(in: "OPENAI_KEY=sk-abcdefghijklmnopqrstu and more")
        expect(m2?.rule.id == "openai-api-key", "openai match")

        let m3 = scanner.firstMatch(in: "lorem ipsum dolor sit amet, consectetur adipiscing elit")
        expect(m3 == nil, "no false positive on prose")

        let onlyKw = SecretRule(raw: [
            "id": .string("kw-test"),
            "regex": .string(#"abc"#),
            "keywords": .array(["NEVERPRESENT"]),
            "description": .string("kw")
        ])!
        let kwScanner = SecretScanner(rules: [onlyKw])
        let m4 = kwScanner.firstMatch(in: "abc abc abc")
        expect(m4 == nil, "prefilter skips rule when no keyword present")

        let entropyRule = SecretRule(raw: [
            "id": .string("entropy-test"),
            "regex": .string(#"token=([A-Za-z0-9]{12})"#),
            "keywords": .array(["token="]),
            "entropy": .bareLiteral("3.0"),
            "secretGroup": .bareLiteral("1")
        ])!
        let entropyScanner = SecretScanner(rules: [entropyRule])
        expect(entropyScanner.firstMatch(in: "token=aaaaaaaaaaaa") == nil, "rejects low entropy match")
        let highEntropy = entropyScanner.firstMatch(in: "token=aB3dE5gH7jK9")
        expect(highEntropy?.secret == "aB3dE5gH7jK9", "accepts high entropy secret group")
        let laterHighEntropy = entropyScanner.firstMatch(in: "token=aaaaaaaaaaaa token=aB3dE5gH7jK9")
        expect(laterHighEntropy?.secret == "aB3dE5gH7jK9", "continues after low entropy match")

        let fullMatchEntropyRule = SecretRule(raw: [
            "id": .string("full-match-entropy-test"),
            "regex": .string(#"key-[A-Za-z0-9]{12}"#),
            "keywords": .array(["key-"]),
            "entropy": .bareLiteral("3.0")
        ])!
        let fullMatchEntropyScanner = SecretScanner(rules: [fullMatchEntropyRule])
        expect(fullMatchEntropyScanner.firstMatch(in: "key-aaaaaaaaaaaa") == nil, "rejects low entropy full match")
        expect(fullMatchEntropyScanner.firstMatch(in: "key-aB3dE5gH7jK9")?.secret == "key-aB3dE5gH7jK9", "accepts high entropy full match")

        // RE2→ICU dialect transcription: `(?P<name>…)` named groups (gitleaks
        // jwt-base64 style) must compile and match via NSRegularExpression.
        let goNamedGroups = SecretRule(raw: [
            "id": .string("go-named-groups"),
            "regex": .string(#"\bZXlK(?:(?P<alg>aGJHY2lPaU)|(?P<key_ops>clpYbGZiM0J6SWpwY)|(?P<kid>cmFXUWlP))[a-zA-Z0-9/\\_+\-]{8,}"#),
            "description": .string("jwt-like")
        ])
        expect(goNamedGroups != nil, "(?P<name>…) pattern transcribed and compiled")
        let goScanner = SecretScanner(rules: [goNamedGroups!])
        expect(
            goScanner.firstMatch(in: "ZXlKaGJHY2lPaUpJVXpJMU5pSXNJbn") != nil,
            "transcribed named-group pattern matches")

        // RE2→ICU dialect transcription: a bare `}}` (gitleaks kubernetes-secret-yaml
        // style) is retried with the braces escaped.
        let bareBraces = SecretRule(raw: [
            "id": .string("bare-closing-braces"),
            "regex": .string(#"\{\{[ \t\w"|$:=,.-]+}}"#),
            "description": .string("template ref")
        ])
        expect(bareBraces != nil, "bare }} pattern compiled via escaped retry")
        let braceScanner = SecretScanner(rules: [bareBraces!])
        expect(braceScanner.firstMatch(in: "password: {{ .Values.secret }}")?.secret == "{{ .Values.secret }}", "escaped-brace pattern matches")

        print("SecretScannerTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
