import Foundation
import Testing

/// Private keys made by `ssh-keygen` (OpenSSH 10.5) for these tests, with the
/// public key and fingerprint the same tool reported for each.
///
/// They were generated for this file and are used nowhere else: nothing
/// trusts them, and they are published here on purpose.
enum SSHKeyFixtures {
    struct Key: Sendable, CustomTestStringConvertible {
        var name: String
        /// The contents of the private key file.
        var privateKey: String
        var passphrase: String?
        /// The `.pub` file's line, without the comment.
        var publicKey: String
        var comment: String
        /// What `ssh-keygen -lf` prints for the key.
        var fingerprint: String
        var algorithmName: String

        var testDescription: String { name }
    }

    /// An Ed25519 key without a passphrase.
    static let ed25519 = Key(
        name: "ed25519",
        privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACASC+xabzNZKk/zI5d6Z99Mv0QfKAABG94W4bs7U9h56gAAAJhle0ysZXtM
        rAAAAAtzc2gtZWQyNTUxOQAAACASC+xabzNZKk/zI5d6Z99Mv0QfKAABG94W4bs7U9h56g
        AAAEDlXOQYQH59ytV1qm7UcL8PkP9sKkMan3tEHH21+OAHPxIL7FpvM1kqT/Mjl3pn30y/
        RB8oAAEb3hbhuztT2HnqAAAAD2ZpeHR1cmUgZWQyNTUxOQECAwQFBg==
        -----END OPENSSH PRIVATE KEY-----
        """,
        passphrase: nil,
        publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBIL7FpvM1kqT/Mjl3pn30y/RB8oAAEb3hbhuztT2Hnq",
        comment: "fixture ed25519",
        fingerprint: "SHA256:H+f68cT9cZ+kacj/Vuh3uTTE36Ek4zc0CRJQ5jL7ePI",
        algorithmName: "Ed25519")

    /// An Ed25519 key protected the way `ssh-keygen` does by default: `aes256-ctr`,
    /// 24 rounds of bcrypt.
    static let ed25519Protected = Key(
        name: "ed25519Protected",
        privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCjwETB5c
        kDwBlA2lVMDz04AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIOh+HtC1A/QSIfTW
        Gpuiz5zs81J2c5Fysj/N4jUe1D/uAAAAoJ/adGb8fBpzvNdz5oxHpeCTddjqjCZ9qM0peZ
        cN+ibXIxHAuAtZOWQebE7B+NM3L38oHeQXV4SR/2PdGfmmXplEXyCD3o4IoFDIN8E8AwvK
        FqOaUHGMbzFJV9UCeoOhzWnUn0TKLgClGxQIOSVEca+Kriio4BlTJR+tPOIrTo3SKSSJum
        Z/UsxpBGiNY51iMKCTOM5F6rBpEK1sv3zxgIw=
        -----END OPENSSH PRIVATE KEY-----
        """,
        passphrase: "correct horse battery staple",
        publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOh+HtC1A/QSIfTWGpuiz5zs81J2c5Fysj/N4jUe1D/u",
        comment: "fixture ed25519 encrypted",
        fingerprint: "SHA256:ZArMuo/bTP+pgS6rfNgaJ4cmR8ZhblZ0S6f2uJEPZnM",
        algorithmName: "Ed25519")

    /// An ECDSA P-256 key without a passphrase.
    static let p256 = Key(
        name: "p256",
        privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQWVkuM583NS4qpyfPqjJqLFeGFJdKX
        4A/8mirz1YOz+fL4B0FDrzjXLSAusd7jSyac1fVp3qvfBHMk6QvrFN/iAAAAqF43EApeNx
        AKAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBZWS4znzc1LiqnJ
        8+qMmosV4YUl0pfgD/yaKvPVg7P58vgHQUOvONctIC6x3uNLJpzV9Wneq98EcyTpC+sU3+
        IAAAAgD3YW9nu09Cm5vko0ZFqhXGNBvuokp/omq9IV3RCJXFQAAAAMZml4dHVyZSBwMjU2
        AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
        """,
        passphrase: nil,
        publicKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBZWS4znzc1LiqnJ8+qMmosV4YUl0pfgD/yaKvPVg7P58vgHQUOvONctIC6x3uNLJpzV9Wneq98EcyTpC+sU3+I=",
        comment: "fixture p256",
        fingerprint: "SHA256:5s66LW1Ha723fe/F3hHL0O+Nn1G4ehEK50V5Mfg5urk",
        algorithmName: "ECDSA P-256")

    /// An ECDSA P-384 key protected with `aes256-gcm@openssh.com` and a passphrase
    /// outside ASCII.
    static let p384Protected = Key(
        name: "p384Protected",
        privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAAFmFlczI1Ni1nY21Ab3BlbnNzaC5jb20AAAAGYmNyeXB0AA
        AAGAAAABCzHGEx1+O4LfjyBpk8VCC5AAAABAAAAAEAAACIAAAAE2VjZHNhLXNoYTItbmlz
        dHAzODQAAAAIbmlzdHAzODQAAABhBGiqphoFIi0EsUpWeJmYizT1lp+MCAKHIAmns9YIcD
        d5F4hfBec6lHgWOR0Vdkh3064LtpyzNUu6IxopgCo5hUs9L5oC8GRqxkSsJZhlaugi/gIh
        93ibGhKLzvoAsU6bCgAAAOCVTGjQqyBbGEgGvoRmkkz4Iqg/QryesER+Qwx1E5yNiAWApf
        MnUPd59lC3tsPun4YVjKTocjzzJzcb/5gXHRqyM3YveIw6BwGc0g7gZD1rqoPwADQIeUo/
        LflYShYFyveOf/uGsQEcyTC6BghxG5Yaq4zJSCQvIqidTipvS79RROr7DaRjJiffSu7CAT
        X/UDsF9ZJLHOKblAGaI26mG6tsHB1/7/al5FLz1CAflU4yvRt6wf6iIU6jAqap5aHf2eBd
        ncLS/yFC7yXBdQeeYUTV7R7mGPy0p8On+YKwvr0MVV5PpIDTIAjy7NK1mVQol+0=
        -----END OPENSSH PRIVATE KEY-----
        """,
        passphrase: "pässphrase ✓",
        publicKey: "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBGiqphoFIi0EsUpWeJmYizT1lp+MCAKHIAmns9YIcDd5F4hfBec6lHgWOR0Vdkh3064LtpyzNUu6IxopgCo5hUs9L5oC8GRqxkSsJZhlaugi/gIh93ibGhKLzvoAsU6bCg==",
        comment: "fixture p384 gcm",
        fingerprint: "SHA256:8doc4OMUZfaQ31Zsz6HVosg71qfcevHAresZmjGLelU",
        algorithmName: "ECDSA P-384")

    /// An ECDSA P-521 key without a passphrase.
    static let p521 = Key(
        name: "p521",
        privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
        1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQA+02w1cj6W598a9vdWyD2YiN++7kh
        tK+S0vYlVXaK3Z0DK5UyrBbh7EOYZvb8s6kY7cvtx1mCwvYmF2DxtK420toBaWasduJqUW
        7jaLaVAOcS9HB8avqBgz4WIfls6b8Bkll4/N8yh2FaA9QaCauGB/Ctsat7aTVv0SUrWAMb
        jrypBOYAAAEQJMtdAyTLXQMAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
        AAAIUEAPtNsNXI+luffGvb3Vsg9mIjfvu5IbSvktL2JVV2it2dAyuVMqwW4exDmGb2/LOp
        GO3L7cdZgsL2Jhdg8bSuNtLaAWlmrHbialFu42i2lQDnEvRwfGr6gYM+FiH5bOm/AZJZeP
        zfModhWgPUGgmrhgfwrbGre2k1b9ElK1gDG468qQTmAAAAQXOjcjEtPNG+b8TvWADNjXQi
        mK29KVSddCK0R6KjVYja0EF4BtocSkKjjqV5o6NF0x1feBn0yRtlkiXlQjVenw/jAAAADG
        ZpeHR1cmUgcDUyMQECAwQFBgc=
        -----END OPENSSH PRIVATE KEY-----
        """,
        passphrase: nil,
        publicKey: "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAD7TbDVyPpbn3xr291bIPZiI377uSG0r5LS9iVVdordnQMrlTKsFuHsQ5hm9vyzqRjty+3HWYLC9iYXYPG0rjbS2gFpZqx24mpRbuNotpUA5xL0cHxq+oGDPhYh+WzpvwGSWXj83zKHYVoD1BoJq4YH8K2xq3tpNW/RJStYAxuOvKkE5g==",
        comment: "fixture p521",
        fingerprint: "SHA256:POmNeOUutxlOWI5IEpA0ysUiubELtSmuDvo6jLckhPI",
        algorithmName: "ECDSA P-521")

    static let all = [ed25519, ed25519Protected, p256, p384Protected, p521]

    /// An RSA key without a passphrase. RSA cannot be used to sign in.
    static let rsaPrivateKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAIEAt+mgjt3B1xfIZSTuLXP+xYfwI9iR3Xv48QGijEsN/XTZbDcV3LtW
        SwU2bsxmcihVp+pAuH8A/12b/LqbUMwZdG+b++9U9Zs6a9ApoQTJqI3XeBjNcJDsYD8h4+
        HuhphqbdvTJP7pEhS9myVJFqlxEbSzFTsULIP2zeHhLoCPKxsAAAIIUCeb0lAnm9IAAAAH
        c3NoLXJzYQAAAIEAt+mgjt3B1xfIZSTuLXP+xYfwI9iR3Xv48QGijEsN/XTZbDcV3LtWSw
        U2bsxmcihVp+pAuH8A/12b/LqbUMwZdG+b++9U9Zs6a9ApoQTJqI3XeBjNcJDsYD8h4+Hu
        hphqbdvTJP7pEhS9myVJFqlxEbSzFTsULIP2zeHhLoCPKxsAAAADAQABAAAAgG0wImfPlq
        7Z6trJ4zJPJJony9WsVWV2neSQQO4j/UlWH2OVDMDA5Emj7Z44cjYiZkBL3mLq3C/AZsTU
        ETQWCKHK8C7fdobtOH3gbNHktGknYwjxzBOzyLP45L+N/a6JzS5JQLJrv8oc0ecsygt+RK
        x3CQeGWpW/+o1UhFn5ciqpAAAAQQCMuwB9SaMvZ/DxTdCVXcecdLsH6KgMGAD1nYZMR+BU
        bsBo5pmMrtjKTHjpBzFyU69xwim0mKNYDjD3fuuoiB3CAAAAQQDpZ1IfJ6zZN48g8TYF5D
        kcQesla8NFBG+vnHLg6OcuRdVlP4+A+0YRTLN5quTyLzjlI/2SkmtoAUVRSuwKQe8HAAAA
        QQDJt7iB57KEhf8b1FX1LSb9+ADcsFnMLSg7Z57RhfiiqzyoPrKumIIkUzZANqbGg40VSp
        Vc3mRyca3c/wpwfApNAAAAC2ZpeHR1cmUgcnNhAQIDBAUGBw==
        -----END OPENSSH PRIVATE KEY-----
        """

    /// An RSA key protected by a passphrase, which these tests never supply.
    static let protectedRSAPrivateKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAV/mexp5
        mKmFHcDD1areHiAAAAGAAAAAEAAACXAAAAB3NzaC1yc2EAAAADAQABAAAAgQC5V2dZ+MDg
        I4NZ2iRlhkir9F4vzSTrh4+BTAByryLgX+BM0Wvv1McGoZulahwJEZO9/V7OX7q28sivCU
        7MnuPCt2+pzc/Gz7GBSs9gxzxk/u8CsQC2pBSFFiDE4SypWKHgQYQxQ45d4UY87fYWV62K
        CYIDZ5E8Pjn3YAKkrZAtjQAAAhB9g1ImYjUTxIU40PCWB+kRY0Ok2ylLH0zx+4bTvJDNOv
        2HbpJliUA0B6S7i/iAto6EqrsEO9KIvJlVguuFvBwbKKhc3wo8gfPibpY17WtkO9S94/2r
        zaiWpKFKItZTTmRwJln5iPjee9ZaQlu/dwhIbJVw5JYoC2clbW8YWWefs9PpmnK/7qBZu+
        f4EWpHL3EvQ4ym8GsXPKeVmQ9pvmK/kVImVsQUuMxoXz7+PWGcc/ZyOf78637G1bbq13NZ
        IufWAlre+4hzfjusrC56UT7AF8DuhH54ghjSxug+Kb0Cxysk1biFxwiaGgB2KV2Tfffy2f
        DI8mp0DWeOxL/8ihDf8o12iE1QniRrfF5yL6th4YdFXqQSJWiI/NTT/KvW+RS/C5BQ6/27
        WcsxE0/P6OueG03uUYTGJyUODl7TkBzcRtV/he0FPdEj9jMk2MhtG88xrq0pmgixOmTN2Z
        bG4znhK5RAp3/+wcSWIg+D0DcK/kWKi/QNnxbj9ykmh/Zr6MWK0W+6mYDOLv4RHA64JD73
        3c3i/lrEG0/dHNqSBQpEJFDwDM0YkOcayt01ZrU3/DLTnUfbqJ0YrdBc9w/ZsRh4ciFDVT
        kxycMlnD9wRTEJ/3pPx6r/J8s3Tc2ZdVqQugnNe73CGQrZWbptS21M2Ub/YqI6FD+FJlBm
        40kSzl0cWhX5fbJuGNXJ/EYhzAKi+PU=
        -----END OPENSSH PRIVATE KEY-----
        """
}
