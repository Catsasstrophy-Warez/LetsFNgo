import Foundation
import NexusCommunications
import Testing

@Suite struct EmailParsingTests {
    @Test func multipartMessageWithAlternativeBodiesAndAnAttachment() throws {
        let email = EmailMessage(Fixtures.loopReport)
        #expect(email.messageID == "loop-1@plant.example")
        #expect(email.subject == "LT-101 reads low — 4.0 mA at empty")
        #expect(email.from == [EmailAddress(name: "Ruiz, Ana", address: "ana@plant.example")])
        #expect(email.to.map(\.address) == ["ben@plant.example", "chloe@plant.example"])
        #expect(email.to.map(\.name) == ["Ben Okafor", "Chloé Martin"])
        #expect(email.cc == [EmailAddress(name: "Ops desk", address: "ops@plant.example")])
        // 10:52:37 +0200 is 08:52:37 UTC.
        #expect(email.date == RFC5322Date.parse("1 Sep 2026 08:52:37 GMT"))
        #expect(email.text == "The level transmitter LT-101 reads 4.0 mA with the tank at 50 — please check the loop.\nSerial on the plate is ABC12345X.")
        #expect(email.html?.contains("<b>LT-101</b>") == true)
        #expect(email.attachments.count == 1)
        let pdf = try #require(email.attachments.first)
        #expect(pdf.filename == "loop check – LT-101.pdf")
        #expect(pdf.mediaType == "application/pdf")
        #expect(pdf.data == Data(base64Encoded: "JVBERi0xLjQKJcOkw7zDtsOfCg=="))
        #expect(!pdf.isInline)
    }

    @Test func htmlOnlyFallsBackToText() {
        let email = EmailMessage(Fixtures.htmlOnly)
        #expect(email.text == "Café & tea\n• one\n• two")
        #expect(email.from == [EmailAddress(address: "vendor@vendor.example")])
        #expect(email.date == Date(timeIntervalSince1970: 1_788_336_000))
        #expect(email.attachments.isEmpty)
    }

    @Test func headersUnfoldAndIgnoreCase() {
        let headers = MIMEHeaders.parse("From ignored line\nSubject: one\n two\nX-A: 1\nx-a: 2\n")
        #expect(headers["subject"] == "one two")
        #expect(headers.all("X-A") == ["1", "2"])
        #expect(headers["From"] == nil)
    }

    @Test func parametersQuotedAndRFC2231Continuations() {
        let type = MIMEParameterized("Text/Plain; charset=\"UTF-8\"; format=flowed; name*0*=utf-8''a%20b; name*1=\"; c.txt\"")
        #expect(type.value == "text/plain")
        #expect(type.parameters["charset"] == "UTF-8")
        #expect(type.parameters["format"] == "flowed")
        #expect(type.parameters["name"] == "a b; c.txt")
    }

    @Test func transferEncodings() {
        #expect(MIMEDecoding.quotedPrintable(Array("a=3Db=\r\nc=\nd".utf8)) == Array("a=bcd".utf8))
        #expect(MIMEDecoding.base64(Array("aGVs\r\nbG8".utf8)) == Data("hello".utf8))
        #expect(MIMEDecoding.decodeWords("=?ISO-8859-1?Q?Caf=E9?= ok") == "Café ok")
        #expect(MIMEDecoding.decodeWords("=?utf-8?B?SGk=?= =?utf-8?B?IHRoZXJl?=") == "Hi there")
        #expect(MIMEDecoding.decodeWords("plain =?bogus") == "plain =?bogus")
    }

    @Test func addressLists() {
        let list = EmailAddress.list("\"Doe, J\" <j@x.io>, k@x.io (Kay), team: l@x.io, m@x.io;, <n@x.io>, not-an-address")
        #expect(list.map(\.address) == ["j@x.io", "k@x.io", "l@x.io", "m@x.io", "n@x.io"])
        #expect(list.map(\.name) == ["Doe, J", "Kay", nil, nil, nil])
        let ana = EmailAddress(name: "Ruiz, Ana", address: "Ana@X.io")
        #expect(ana.description == "\"Ruiz, Ana\" <ana@x.io>")
        #expect(EmailAddress.list(ana.description) == [ana])
    }

    @Test func dates() {
        let utc = RFC5322Date.parse("Tue, 01 Sep 2026 08:52:37 +0000")
        #expect(RFC5322Date.parse("1 Sep 2026 04:52:37 EDT") == utc)
        #expect(RFC5322Date.parse("Tue, 1 Sep 26 01:52:37 -0700 (PDT)") == utc)
        #expect(RFC5322Date.parse("not a date") == nil)
        #expect(RFC5322Date.format(utc!) == "Tue, 1 Sep 2026 08:52:37 +0000")
    }

    @Test func subjectsNormaliseForThreading() {
        #expect(EmailMessage.normalizedSubject("Re: FWD: [ops]  Pump   P-7 seal") == "pump p-7 seal")
        #expect(EmailMessage.normalizedSubject("AW: Re : Lunch") == "lunch")
    }

    @Test func mboxSplitsAndUnquotesFromLines() {
        let messages = MBox.messages(Fixtures.mailbox).map(EmailMessage.init)
        #expect(messages.map(\.subject) == ["Pump P-7 seal", "Re: Pump P-7 seal", "Lunch"])
        #expect(messages[1].text == "Yes, two kits.\nFrom the stores list.")
        #expect(messages[1].references == ["q-1@plant.example"])
        #expect(messages[2].messageID == nil)
        #expect(MBox.messages(Data("no from line".utf8)).isEmpty)
    }

    @Test func htmlToText() {
        #expect(HTMLText.plain("<p>A&#39;s &#x263A;</p><br/>B<div>C</div>") == "A's ☺\n\nB\nC")
    }
}
