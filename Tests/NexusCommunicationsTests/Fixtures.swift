import Foundation

/// Email files used across the communications tests. Line endings are CRLF
/// where a real .eml would have them.
enum Fixtures {
    static let t0 = Date(timeIntervalSinceReferenceDate: 810_000_000)

    static func crlf(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    /// multipart/mixed → multipart/alternative (quoted-printable text, HTML)
    /// plus a base64 PDF with an RFC 2231 file name. Encoded-word subject,
    /// folded To header, a comment in the date.
    static let loopReport = crlf(
        """
        Return-Path: <ana@plant.example>
        Message-ID: <loop-1@plant.example>
        Date: Tue, 1 Sep 2026 10:52:37 +0200 (CEST)
        From: "Ruiz, Ana" <Ana@Plant.example>
        To: Ben Okafor <ben@plant.example>,
         =?utf-8?Q?Chlo=C3=A9_Martin?= <chloe@plant.example>
        Cc: ops@plant.example (Ops desk)
        Subject: =?utf-8?B?TFQtMTAxIHJlYWRzIGxvdyDigJQgNC4w?=
         =?utf-8?Q?_mA_at_empty?=
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer"

        This is a multi-part message in MIME format.
        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        The level transmitter LT-101 reads 4.0 mA with the tank at 50 =E2=80=94 =
        please check the loop.
        Serial on the plate is ABC12345X.
        --inner
        Content-Type: text/html; charset=utf-8

        <html><body><p>The level transmitter <b>LT-101</b> reads 4.0&nbsp;mA</p></body></html>
        --inner--

        --outer
        Content-Type: application/pdf; name="ignored.pdf"
        Content-Disposition: attachment; filename*=utf-8''loop%20check%20%E2%80%93%20LT-101.pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQKJcOkw7zDtsOfCg==
        --outer--

        """)

    /// HTML only, Latin-1, with an entity and a script to drop.
    static let htmlOnly = crlf(
        """
        Message-ID: <html-1@vendor.example>
        Date: 2 Sep 2026 08:00 GMT
        From: vendor@vendor.example
        To: ana@plant.example
        Subject: Datasheet
        Content-Type: text/html; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable

        <html><head><style>p{color:red}</style></head><body><script>alert(1)</script>
        <p>Caf=E9 &amp; tea</p><ul><li>one</li><li>two</li></ul></body></html>
        """)

    /// Three messages: a question, a reply by References with a quoted
    /// "From " line, and an unrelated message with no Message-ID.
    static let mailbox = Data(
        """
        From ana@plant.example Tue Sep  1 08:52:37 2026
        Message-ID: <q-1@plant.example>
        Date: Tue, 1 Sep 2026 08:52:37 +0000
        From: Ana Ruiz <ana@plant.example>
        To: Ben Okafor <ben@plant.example>
        Subject: Pump P-7 seal

        Is the seal kit for P-7 in stock?

        From ben@plant.example Tue Sep  1 09:10:00 2026
        Message-ID: <q-2@plant.example>
        In-Reply-To: <q-1@plant.example>
        References: <q-1@plant.example>
        Date: Tue, 1 Sep 2026 09:10:00 +0000
        From: Ben Okafor <ben@plant.example>
        To: Ana Ruiz <ana@plant.example>
        Subject: Re: Pump P-7 seal

        Yes, two kits.
        >From the stores list.

        From carl@else.example Wed Sep  2 12:00:00 2026
        Date: Wed, 2 Sep 2026 12:00:00 -0500
        From: carl@else.example
        To: ana@plant.example
        Subject: Lunch

        Friday?

        """.utf8)
}
