import Foundation

@main
struct KindClassifierTestRunner {
    static func main() throws {
        let fakePattern = try NSRegularExpression(pattern: "AKIA[0-9A-Z]{16}", options: [])
        let secret = SecretRule(id: "test-aws", regex: fakePattern, keywords: ["AKIA"])
        let c = KindClassifier(secretRules: [secret])

        expect(c.classify("https://example.com/path") == .url, "url positive")
        expect(c.classify("/etc/passwd") == .filePath, "absolute filePath")
        expect(c.classify("~/Documents/x") == .filePath, "tilde filePath")
        expect(c.classify("file:///tmp/x") == .filePath, "file:// filePath")
        expect(c.classify("#fff") == .color, "3-digit color")
        expect(c.classify("#1A2B3C") == .color, "6-digit color")
        expect(c.classify("AKIAIOSFODNN7EXAMPLE") == .secret, "secret positive")
        expect(c.classify(#"{"a":1}"#) == .codeJSON, "json object")
        expect(c.classify("[1,2,3]") == .codeJSON, "json array")
        expect(c.classify("<?xml version=\"1.0\"?><a/>") == .codeXML, "xml prolog")
        expect(c.classify("<!DOCTYPE html><html></html>") == .codeHTML, "html doctype")
        expect(c.classify("hello world") == .plain, "plain")

        expect(c.classify(#"{"u":"https://x.com"}"#) == .codeJSON, "json beats url")
        expect(c.classify("AKIAIOSFODNN7EXAMPLE") == .secret, "secret wins")
        expect(c.classify("/etc/foo\nbar baz") == .plain, "multiline filePath rejected")
        expect(c.classify("") == .plain, "empty -> plain")
        expect(c.classify("   \n  ") == .plain, "whitespace -> plain")

        print("KindClassifierTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

private extension SecretRule {
    init(id: String, regex: NSRegularExpression, keywords: [String]) {
        self.init(raw: [
            "id": .string(id),
            "regex": .string(regex.pattern),
            "keywords": .array(keywords),
        ])!
    }
}
