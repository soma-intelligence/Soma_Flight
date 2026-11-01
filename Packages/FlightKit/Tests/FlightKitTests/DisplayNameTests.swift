import Foundation
import Testing
@testable import FlightKit

@Suite struct DisplayNameTests {
    private func id(_ provider: AuthProvider = .email, email: String? = nil, full: String? = nil,
                    given: String? = nil, family: String? = nil) -> AccountIdentity {
        AccountIdentity(provider: provider, email: email, fullName: full, givenName: given, familyName: family)
    }

    @Test func typedNameWinsOverEverything() {
        #expect(DisplayName.resolve(typed: "  Ada   Lovelace ", identity: id(.apple, full: "Augusta King")) == "Ada Lovelace")
    }

    @Test func providerFullNameThenGivenAndFamily() {
        #expect(DisplayName.resolve(typed: "", identity: id(.google, full: "Grace Hopper", given: "G")) == "Grace Hopper")
        #expect(DisplayName.resolve(typed: nil, identity: id(.apple, given: "Grace", family: "Hopper")) == "Grace Hopper")
        #expect(DisplayName.resolve(typed: nil, identity: id(.apple, given: "Grace")) == "Grace")
    }

    @Test func hideMyEmailNeverBecomesAName() {
        #expect(DisplayName.isPrivateRelay("j3k9x2abc@privaterelay.appleid.com"))
        #expect(DisplayName.isPrivateRelay("Jean.Dupont@PrivateRelay.AppleID.com"))
        #expect(DisplayName.resolve(typed: nil, identity: id(.apple, email: "j3k9x2abc@privaterelay.appleid.com")) == "")
        // Even a relay address whose local part reads like a name.
        #expect(DisplayName.resolve(typed: nil, identity: id(.apple, email: "jean.dupont@privaterelay.appleid.com")) == "")
        // iCloud+ Hide My Email addresses carry digits.
        #expect(DisplayName.isPrivateRelay("dense.crane_0q@icloud.com"))
        #expect(DisplayName.nameFromEmail("dense.crane_0q@icloud.com") == nil)
    }

    @Test func appleRelayWithANameUsesTheName() {
        let apple = id(.apple, email: "j3k9x2abc@privaterelay.appleid.com", given: "Élodie", family: "Dupré")
        #expect(DisplayName.resolve(typed: nil, identity: apple) == "Élodie Dupré")
    }

    @Test func normalGmailLocalPartReadsAsAName() {
        #expect(DisplayName.resolve(typed: nil, identity: id(email: "jean.dupont@gmail.com")) == "Jean Dupont")
        #expect(DisplayName.resolve(typed: nil, identity: id(email: "maya_lin@gmail.com")) == "Maya Lin")
        #expect(DisplayName.resolve(typed: nil, identity: id(email: "quentin@gmail.com")) == "Quentin")
        #expect(!DisplayName.isPrivateRelay("quentin@icloud.com"))
        #expect(DisplayName.nameFromEmail("quentin@icloud.com") == "Quentin")
    }

    @Test func idLikeLocalPartsAreRefused() {
        for email in ["123456789@gmail.com", "j3k9x2abc@gmail.com", "user2048@gmail.com", "a.b.c@gmail.com",
                      "deadbeefcafe@gmail.com", "xkcdqrstvw@gmail.com", "jd@gmail.com.x", "j@gmail.com",
                      "jean-paul.dupont.x@gmail.com", "@gmail.com", "not-an-email"] {
            #expect(DisplayName.nameFromEmail(email) == nil, "\(email)")
        }
        #expect(DisplayName.resolve(typed: nil, identity: id(email: "123456789@gmail.com")) == "")
    }

    @Test func accentsAreKept() {
        #expect(DisplayName.resolve(typed: nil, identity: id(email: "élodie.dupré@laposte.net")) == "Élodie Dupré")
        #expect(DisplayName.resolve(typed: nil, identity: id(.google, full: "José Ñúñez")) == "José Ñúñez")
        #expect(DisplayName.resolve(typed: nil, identity: id(.google, full: "Zoë Brontë-Øster")) == "Zoë Brontë-Øster")
    }

    @Test func junkProviderNamesFallThrough() {
        // A provider "name" that is really an id or an address is skipped, then the next rule applies.
        #expect(DisplayName.resolve(typed: nil, identity: id(.google, email: "ada.byron@gmail.com", full: "a8f3c9d2e1b4")) == "Ada Byron")
        #expect(DisplayName.resolve(typed: nil, identity: id(.google, full: "ada@example.com")) == "")
        #expect(DisplayName.resolve(typed: nil, identity: id(.apple, full: "user 12345678")) == "")
        #expect(DisplayName.resolve(typed: nil, identity: nil) == "")
    }

    @Test func metadataKeysFromBothProviders() {
        let google = AccountIdentity.from(metadata: ["full_name": "Grace Hopper", "avatar_url": "https://lh3.googleusercontent.com/a/x",
                                                     "given_name": "Grace", "family_name": "Hopper"],
                                          provider: .google, email: "grace@gmail.com")
        #expect(google.fullName == "Grace Hopper")
        #expect(google.avatarURL?.host() == "lh3.googleusercontent.com")
        let picture = AccountIdentity.from(metadata: ["name": "Ada", "picture": "http://insecure.example/a.jpg"],
                                           provider: .google, email: nil)
        #expect(picture.fullName == "Ada")
        #expect(picture.avatarURL == nil, "only https pictures")
        var name = PersonNameComponents()
        name.givenName = "Ada"; name.familyName = "Lovelace"
        let apple = AccountIdentity(provider: .apple, email: "x@privaterelay.appleid.com").adding(appleName: name)
        #expect(DisplayName.resolve(typed: nil, identity: apple) == "Ada Lovelace")
    }

    @Test func draftPrefill() {
        let user = UUID()
        // The profile's own names first.
        #expect(ProfileDraft.prefill(profile: UserProfile(userId: user, firstName: "Ada", lastName: "King"),
                                     identity: id(.google, given: "Grace")) == ProfileDraft(firstName: "Ada", lastName: "King"))
        // Then the provider's given and family names.
        #expect(ProfileDraft.prefill(profile: UserProfile(userId: user), identity: id(.apple, given: "Grace", family: "Hopper"))
                == ProfileDraft(firstName: "Grace", lastName: "Hopper"))
        // Then a full name split.
        #expect(ProfileDraft.prefill(profile: nil, identity: id(.google, full: "Ada King Lovelace"))
                == ProfileDraft(firstName: "Ada", lastName: "King Lovelace"))
        // A relay email leaves both fields empty, so onboarding asks.
        #expect(ProfileDraft.prefill(profile: nil, identity: id(.apple, email: "j3k9x2abc@privaterelay.appleid.com")) == ProfileDraft())
        #expect(ProfileDraft(firstName: " Ada ", lastName: "").displayName == "Ada")
        #expect(UserProfile.avatarPath(for: UUID(uuidString: "A7000000-0000-0000-0000-00000000000A")!)
                == "a7000000-0000-0000-0000-00000000000a/avatar.jpg")
    }
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@Suite struct AvatarImageTests {
    /// An 800 x 600 JPEG carrying GPS, camera and date metadata, as a phone photo would.
    private func photoWithMetadata() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.44, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.14, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:31 09:00:00"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func squareJPEGWithNoMetadata() throws {
        let input = try photoWithMetadata()
        #expect(try properties(input)[kCGImagePropertyGPSDictionary] != nil, "the input carries GPS")
        let output = try #require(AvatarImage.jpeg(from: input))
        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let p = try properties(output)
        #expect(p[kCGImagePropertyPixelWidth] as? Int == 512)
        #expect(p[kCGImagePropertyPixelHeight] as? Int == 512)
        #expect(p[kCGImagePropertyGPSDictionary] == nil, "no location")
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil, "no camera")
        #expect((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil, "no date")
        #expect(output.count < 200_000)
    }

    @Test func notAPicture() {
        #expect(AvatarImage.jpeg(from: Data("hello".utf8)) == nil)
    }
}
