import Foundation

/// Turns a WhatsApp JID into something a person can read, wherever one would otherwise be
/// printed bare — a sender, a mention, a group event's actor or subject, a group's creator.
///
/// Three sources, in falling order of trust:
///
/// 1. `ZWAPROFILEPUSHNAME` names a party by its own choice;
/// 2. a `…@s.whatsapp.net` JID's prefix is a phone number and is rendered as one
///    (`+34600111222`), even when nobody has named it;
/// 3. anything else — a bare `@lid`, mostly — is returned unchanged, because a LID carries
///    no information this server can put a face to.
///
/// Deliberately not backed by Apple Contacts. Pulling in that framework would add a TCC
/// permission this server does not otherwise need, and would blur the line between this
/// server's deterministic layer and Claude's own judgement — the server reports
/// `+34600111222`; Claude is what cross-references the Contacts MCP server when a name
/// matters more than that.
///
/// A `…@lid` this server cannot name stays a LID, and there is no fourth source to try:
/// the schema has no table mapping a LID to the phone number behind it. Every table was
/// checked by name and the only column anywhere containing the string "lid" belongs to
/// `ZWAZ1PAYMENTTRANSACTION`, unrelated to identity. WhatsApp's own Mac client presumably
/// resolves this some other way — a server call, most likely — which is exactly the kind of
/// thing this server does not do.
public enum JIDDisplay {

    /// Everything this database knows about one party, in the form the tools pass around.
    public static func identity(
        _ jid: String, profileNames: [String: String], picturePaths: [String: String] = [:]
    ) -> Identity {
        Identity(
            jid: jid, displayName: render(jid, profileNames: profileNames),
            profilePicturePath: picturePaths[jid])
    }

    public static func render(_ jid: String, profileNames: [String: String]) -> String {
        if let name = profileNames[jid], !name.isEmpty {
            return name
        }
        return phoneNumber(jid) ?? jid
    }

    /// `34600111222@s.whatsapp.net` → `+34600111222`. Only that domain's prefix is a phone
    /// number — a `@g.us` or bare `@lid` prefix is an internal id with no such meaning, and
    /// forcing a `+` onto one would invent a phone number that does not exist.
    private static func phoneNumber(_ jid: String) -> String? {
        guard let atIndex = jid.firstIndex(of: "@") else { return nil }
        let domain = jid[jid.index(after: atIndex)...]
        guard domain == "s.whatsapp.net" else { return nil }
        let prefix = jid[jid.startIndex..<atIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        return "+\(prefix)"
    }

    /// Resolves the `@<digits>` mentions WhatsApp writes into `ZTEXT`, where the digits are
    /// a LID's numeric part, and reports who was named.
    ///
    /// The text comes back with `@Ada (99020605243425)` in place of `@99020605243425` when
    /// the LID is known, and unchanged when it is not — an unresolved mention is still a
    /// mention, and hiding it would be a worse answer than an unnamed one. The list is
    /// returned alongside rather than derived from the rendered text, so "who was mentioned"
    /// never depends on parsing a display string back apart.
    ///
    /// A five-digit floor keeps this from firing on something that merely contains an `@`
    /// followed by a short number, which a WhatsApp LID never is.
    public static func mentions(in text: String, profileNames: [String: String])
        -> (text: String, mentions: [Mention])
    {
        guard text.contains("@") else { return (text, []) }
        var result = ""
        var found: [Mention] = []
        var remainder = Substring(text)
        while let atIndex = remainder.firstIndex(of: "@") {
            result += remainder[remainder.startIndex..<atIndex]
            let afterAt = remainder.index(after: atIndex)
            let digits = remainder[afterAt...].prefix { $0.isNumber }
            if digits.count >= 5 {
                let name = profileNames["\(digits)@lid"].flatMap { $0.isEmpty ? nil : $0 }
                found.append(Mention(digits: String(digits), name: name))
                if let name {
                    result += "@\(name) (\(digits))"
                } else {
                    result += remainder[atIndex..<digits.endIndex]
                }
            } else {
                result += remainder[atIndex..<digits.endIndex]
            }
            remainder = remainder[digits.endIndex...]
        }
        result += remainder
        return (result, found)
    }
}
