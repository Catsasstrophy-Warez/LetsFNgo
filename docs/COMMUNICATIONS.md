# Communications and calendar

## What Apple allows

Apple doesn't let third-party apps read Mail or Messages. There is no API to list
mailboxes, fetch messages or read message history on iOS or macOS. So Nexus
gets communications in two ways only:

- **Import.** The person exports messages and imports the files: `.eml` (one
  message; drag a message out of Mail, or use File ▸ Save As) and `.mbox` (Mail's
  Mailbox ▸ Export Mailbox, a folder holding an `mbox` file, or any mbox file).
  Messages (SMS/iMessage) has no export, so text threads can't be imported.
- **Send from Nexus.** Nexus prefills the system composer from an object, report
  or investigation (`MFMailComposeViewController` and
  `MFMessageComposeViewController` on iOS, the "compose email" sharing service
  on macOS, `mailto:` elsewhere). The composer sends; Nexus never does.

## Model (`NexusCommunications`)

- `thread` and `message` objects. People are `person` objects found by email
  address (`email`) or phone (`phone`), linked by `sent` (person → message) and
  `addressedTo` (message → person). Messages belong to threads by `inThread`.
- Replies join their parent's thread through `References` / `In-Reply-To`, else a
  thread with the same subject once "Re:", "Fwd:" and "[list]" are removed.
- The imported file is a `document` whose bytes are a blob. Imported threads,
  messages and people are **recorded** truth with origin `importer(source:)`
  naming that document. Attachments become `document` objects (`attachedTo` the
  message); an HTML body is kept as a blob beside the text.
- `about` links a thread or message to what it concerns. Links the person makes
  (importing from an object's page) are recorded; links found in the text are
  **derived**: a Nexus object ID, or a tag/serial matching an object exactly via
  `NameplateMatcher` ("LT-101"). Loose full-text hits never become links.
- Re-importing adds nothing: messages dedup by Message-ID, or by their bytes.
- A message sent from Nexus is recorded — an outgoing `message` plus a
  `communicationSent` event — **only after the system composer reports it
  sent**. Cancelled, saved and failed compositions record nothing, and neither
  does a `mailto:` hand-off, which reports nothing back. On macOS the sharing
  service's "did share" callback is the only signal, and is what's recorded.

## Calendar (`NexusMeetings/CalendarLink.swift`)

Nexus writes events to the person's calendar with EventKit (full access) for a
task, a meeting or any object, and keeps the link: `calendarEventID`
(`eventIdentifier`) and `calendarExternalID` (`calendarItemExternalIdentifier`)
on the meeting itself or on an `event` object that `schedules` the subject.
Edits in Nexus are written to the calendar first and stored only once it accepts
them. On refresh, changes made in Calendar are stored as **recorded** truth from
the `Calendar` source object with method "calendar"; an event deleted in
Calendar is marked `calendarRemoved`, never deleted from Nexus.

## Not done

- Receiving files from the share sheet needs a Share Extension target; import is
  through the file importer in an object's Communications section.
