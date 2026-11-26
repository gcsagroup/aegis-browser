import Foundation

@main
enum VerifyBundledGeoSite {
    static func main() {
        do {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let candidate = try AccessGeoSiteAdmission.admitBundled(resources: resources)
            guard candidate.receipt.tag == CommandLine.arguments[2], let overseas = candidate.overseas,
                  try !overseas.policy(for: .all).effectiveRules.isEmpty
            else { throw AccessGeoSiteAdmission.Failure.invalidMetadata }
        } catch {
            FileHandle.standardError.write(Data("Bundled GeoSite admission failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
