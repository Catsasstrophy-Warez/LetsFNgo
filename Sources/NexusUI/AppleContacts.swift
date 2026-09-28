#if canImport(Contacts)
import Contacts
import Foundation
import NexusCRM
import NexusCore
import NexusPersistence

/// Reads the person's address book through the Contacts framework, with
/// their permission, and imports it like a vCard file. Read-only: nothing is
/// ever written back to Contacts. The address book becomes a `source`
/// object, so every imported person is recorded truth traced to it.
enum AppleContacts {
    static func importAll(into store: NexusStore, by author: Origin) async throws -> ContactImportResult {
        let granted = try await CNContactStore().requestAccess(for: .contacts)
        guard granted else {
            throw ClassifiedError(
                category: .dataSource, whatHappened: "Contacts access wasn't granted.",
                nextActions: [NextAction("Allow Contacts for Nexus in Settings")]
            )
        }
        let cards = try await Task.detached(priority: .userInitiated) { try readCards() }.value
        let importer = ContactImporter(store: store)
        return try await store.perform { _ in
            let source = try importer.addressBook(named: "Apple Contacts", by: author)
            return try importer.importContacts(cards, from: source, format: "Apple Contacts", by: author)
        }
    }

    /// Every contact as a card. Notes are left out: reading them needs a
    /// separate entitlement.
    private static func readCards() throws -> [ContactCard] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactBirthdayKey,
        ].map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        var cards: [ContactCard] = []
        try CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let emails = contact.emailAddresses.map { $0.value as String }
            let organization = contact.organizationName.isEmpty ? nil : contact.organizationName
            guard let name = CNContactFormatter.string(from: contact, style: .fullName) ?? organization ?? emails.first else { return }
            cards.append(
                ContactCard(
                    formattedName: name, givenName: contact.givenName.isEmpty ? nil : contact.givenName,
                    familyName: contact.familyName.isEmpty ? nil : contact.familyName, organization: organization,
                    department: contact.departmentName.isEmpty ? nil : contact.departmentName, title: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
                    emails: emails, phones: contact.phoneNumbers.map { $0.value.stringValue }, birthday: contact.birthday.flatMap(birthday),
                    uid: "apple-contacts:\(contact.identifier)"
                ))
        }
        return cards
    }

    private static func birthday(_ components: DateComponents) -> String? {
        guard let month = components.month, let day = components.day else { return nil }
        if let year = components.year { return String(format: "%04d-%02d-%02d", year, month, day) }
        return String(format: "--%02d-%02d", month, day)
    }
}
#endif
