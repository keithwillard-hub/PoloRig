import Foundation

/// Pure, stateless template interpolation engine for `$variable_name` syntax.
/// Processes `$variable` placeholders before the existing `{MACRO}` system.
public enum CWTemplateEngine {

    /// Interpolate `$variable_name` placeholders from a dictionary.
    /// Variable names: must start with a letter or underscore, followed by letters, digits, or underscores.
    /// Unknown variables are replaced with empty string.
    /// All values are uppercased for CW transmission.
    public static func interpolate(_ template: String, variables: [String: String]) -> String {
        guard !template.isEmpty else { return "" }

        var result = ""
        var i = template.startIndex

        while i < template.endIndex {
            if template[i] == "$" {
                let afterDollar = template.index(after: i)
                if afterDollar < template.endIndex, isVariableStart(template[afterDollar]) {
                    // Parse variable name
                    var nameEnd = template.index(after: afterDollar)
                    while nameEnd < template.endIndex, isVariableContinuation(template[nameEnd]) {
                        nameEnd = template.index(after: nameEnd)
                    }
                    let name = String(template[afterDollar..<nameEnd])
                    let value = variables[name] ?? ""
                    result += value.uppercased()
                    i = nameEnd
                } else {
                    // Bare $ at end or followed by non-variable char — keep literal
                    result.append("$")
                    i = afterDollar
                }
            } else {
                result.append(template[i])
                i = template.index(after: i)
            }
        }

        return result
    }

    /// Build a standard variable dictionary from current app state.
    public static func standardVariables(
        callsign: String,
        myCallsign: String,
        frequencyHz: Int,
        operatingMode: CIV.Mode?,
        name: String?
    ) -> [String: String] {
        var vars: [String: String] = [
            "callsign": callsign,
            "mycall": myCallsign,
            "rst": operatingMode?.defaultRST ?? "599",
            "freq": CIV.Frequency.formatKHz(frequencyHz),
        ]
        if let name, !name.isEmpty {
            vars["name"] = name
        }
        return vars
    }

    // MARK: - Private

    private static func isVariableStart(_ c: Character) -> Bool {
        c.isLetter || c == "_"
    }

    private static func isVariableContinuation(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
