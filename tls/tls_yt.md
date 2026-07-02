# HTTPS, SSL, TLS & Certificate Authorities — Explained

> **Source:** YouTube — *"HTTPS, SSL, TLS & Certificate Authority Explained"* (video ID `EnY6fSng3Ew`)
> **Notes:** A structured, from-scratch walkthrough of *why* HTTP is insecure, *why* HTTPS is secure, and *how* HTTPS actually works.

The video answers three questions:

1. **Why is HTTP not secure?**
2. **Why is HTTPS secure?**
3. **How is HTTPS secure?**

- **HTTP** = **H**yper**t**ext **T**ransfer **P**rotocol. A *protocol* is just a set of rules.
- **HTTPS** = HTTP + **S** for **Secure**. The security comes from **encryption**.

---

## 1. The Starting Point — Sending Data Over a Network

When you log into a site (e.g. `facebook.com`), your email + password start out living **only on your machine**. Clicking "Log in" sends that data to a **remote server** that validates credentials, talks to a database, and responds.

This machine-to-machine communication is **networking**, and it is *not* magic — data has to physically travel over a **transmission medium**.

### How data is prepared and transmitted

```
Human-readable JSON            Machine-transmittable form
┌────────────────────┐
│ {                  │   1. COMPRESS   ┌───────────────────────┐
│   "email":  "...", │ ──────────────► │ {"email":"...","pw":..}│  (remove whitespace)
│   "password": "..."│                 └───────────┬───────────┘
│ }                  │                             │ 2. CONVERT TO BINARY
└────────────────────┘                             ▼
                                        01001010 01110011 0110...
                                        (same meaning, machine-readable)
```

**Why binary?** Because data must be physically transmitted. The medium is either:

| Type               | Examples of signal                |
| ------------------ | --------------------------------- |
| **Wired**    | Electrical signals, light signals |
| **Wireless** | Radio waves, infrared waves       |

### Example: transmitting bits as electrical signals

A **byte** = 8 **bits**; each bit is `0` or `1`. The sending machine (Machine 1) emits voltages; the receiving machine (Machine 2) reads them back:

```
Machine 1 (sender)                         Machine 2 (receiver)
  sends 0 volts   ──── electrical signal ────►  reads 0 V → bit "0"
  sends 5 volts   ──── electrical signal ────►  reads 5 V → bit "1"
   ...repeat per bit...                          ...reassemble bits → bytes → data
```

### Your real-world setup

```
[ Your machine ] ──(radio waves / Wi-Fi)──► [ Router ] ──(electrical/light)──► [ Facebook server ]
     converts to binary                                                          converts back to data
```

---

## 2. Why HTTP Is NOT Secure

Any data sent over a physical medium (wired *or* wireless) is **100% accessible to the public world**.

- A cheap device (~$17 on Amazon) can **detect radio waves** and convert them back into bytes.
- An attacker "roaming around the room" can capture the binary, convert it to JSON, and read your **email, password, credit card** — anything.

```
        [ Your data → binary ] ═══════════╗ transmitted over the air
                                           ║
                                    ┌──────▼──────┐
                                    │  Attacker   │  captures bytes → converts to JSON
                                    │  ($17 sniffer)│  → reads email + password
                                    └─────────────┘
```

That is exactly why browsers (Chrome, Safari, etc.) label HTTP sites **"Not Secure."** Most users see this warning and leave the page.

**Fix:** Use **HTTPS**, which secures data with **encryption**.

---

## 3. Encryption Basics

**Encryption** scrambles readable data into meaningless text using:

1. A **key** — a string of random characters (numbers + letters).
2. An **algorithm** — e.g. **AES-256** (a famous encryption algorithm).

```
  Readable data  +  Key  +  Algorithm  ──ENCRYPT──►  Scrambled ciphertext
  Scrambled text +  Key  +  Algorithm  ──DECRYPT──►  Readable data again
```

Without the key, the ciphertext is meaningless.

---

## 4. Symmetric Encryption (and Its Fatal Flaw)

**Symmetric encryption** = the **same key** encrypts *and* decrypts.

### The problem

The server needs the key to decrypt your data — but *it doesn't have it, only you do*. If you simply send the key over the network alongside the encrypted data, an attacker captures **both** and decrypts everything.

```
[ You ]  encrypt data with KEY
         send: [encrypted data] + [KEY]  ═══════════╗
                                                     ║
                                              ┌──────▼──────┐
                                              │  Attacker   │  has ciphertext + KEY
                                              └─────────────┘  → decrypts everything ❌
```

**Conclusion:** Sending the symmetric key over the network is *not* a solution. → We need **asymmetric encryption**.

---

## 5. Asymmetric Encryption

Uses **two different keys**: a **public key** and a **private key**.

**Rule:** whatever *one* key encrypts, only the *other* key can decrypt.

```
Encrypt with PUBLIC key   ──►  Decrypt only with PRIVATE key
Encrypt with PRIVATE key  ──►  Decrypt only with PUBLIC key
```

- **Public key** — shared with the whole world (safe to Google).
- **Private key** — known **only** to the server.

### Securely establishing a shared symmetric key

```
[ Your machine ]                                   [ Server ]
      │                                          (has PUBLIC + PRIVATE key)
      │  1. "I want to send you data"  ─────────────►│
      │                                              │
      │◄──────────── 2. sends its PUBLIC key ────────│
      │                                              │
      │  3. encrypt your SYMMETRIC key               │
      │     using server's PUBLIC key                │
      │                                              │
      │  4. send encrypted symmetric key  ──────────►│
      │                                              │  5. decrypt it with PRIVATE key
      │                                              │
      └── Both sides now share the SYMMETRIC key ────┘
          → use it for fast, secure communication
```

**Why this is safe from a passive eavesdropper:** the attacker can see the public key (it's public) and the encrypted symmetric key — but **cannot decrypt** it, because decryption requires the **private key**, which only the server holds.

---

## 6. The Man-in-the-Middle (MITM) Attack

Asymmetric encryption alone is **still not enough**. An active attacker can **intercept** the conversation.

```
[ Your machine ]            [ Attacker (MITM) ]            [ Real Server ]
      │                            │                            │
      │ "I want to send data" ────►│ (intercepts)               │
      │                            │                            │
      │◄── attacker's PUBLIC key ──│  (pretends to be server)   │
      │                            │                            │
      │ encrypt symmetric key      │                            │
      │ with ATTACKER's public key │                            │
      │ send it ──────────────────►│ decrypts with attacker's   │
      │                            │ PRIVATE key → HAS your key! │
      │                            │                            │
      │ send sensitive data  ─────►│  decrypts everything ❌      │
```

The victim's machine **has no idea** the public key came from an attacker rather than the real server.

**The missing guarantee:** We must be able to **prove the public key genuinely belongs to the real server.** → Solved by **Certificate Authorities**.

---

## 7. Certificate Authorities (CAs) — The Final Solution

A **Certificate Authority** is a **trusted third-party entity** that browsers (Chrome, Firefox, Safari…) trust by default. Becoming one requires a rigorous process — only ~12 widely-trusted CAs exist.

> Examples mentioned: **DigiCert, Let's Encrypt, Cybertrust, Comodo (Sectigo)**.

Like a server, a CA has its own **public key** (world-accessible) and **private key** (secret to the CA).

### What a certificate contains

A **certificate** is simply a text file with **three parts**:

```
┌──────────────────────────────────────────────────────────┐
│ CERTIFICATE                                                │
├──────────────────────────────────────────────────────────┤
│ PART 1 — Information                                       │
│   • Issued TO (owner):  facebook.com, Berlin, ...          │
│   • Issued BY (issuer): DigiCert, Canada, ...              │
├──────────────────────────────────────────────────────────┤
│ PART 2 — Server's PUBLIC KEY                               │
│   (the server sent this to the CA)                         │
├──────────────────────────────────────────────────────────┤
│ PART 3 — SIGNATURE                                         │
│   = Server's public key ENCRYPTED with the CA's PRIVATE key│
└──────────────────────────────────────────────────────────┘
```

> ⚠️ The CA's **private key is never sent**. Only the *result* of signing (the encrypted server public key) is placed in the certificate.

### The full HTTPS handshake with a CA

```
                       ┌───────────────────┐
                       │ Certificate        │
                       │ Authority (CA)     │
                       └─────────▲──┬───────┘
     server's public key         │  │ signed certificate
                                  │  ▼
[ Your machine ]            [ Server (facebook.com) ]
      │                            │
      │ 1. "I want to send data"──►│
      │                            │ 2. sends its public key to the CA
      │                            │ 3. CA builds + signs the certificate
      │◄──── 4. certificate ───────│    (returns it to the server)
      │
      │ 5. Read the certificate's issuer (e.g. DigiCert)
      │ 6. Fetch DigiCert's PUBLIC key
      │ 7. DECRYPT the signature with the CA's public key
      │        → gives the "decrypted server public key"
      │ 8. VERIFY:
      │        decrypted server public key  ==  server public key in cert?
      │        ✔ match  → the public key genuinely belongs to the server
      │
      └─ 9. Proceed with the asymmetric exchange (Section 5) to
            establish the symmetric key → secure session ✅
```

**Why MITM now fails:** An attacker cannot forge a valid signature, because signing requires the **CA's private key** (which they don't have). If the signature doesn't decrypt to match the server's public key, verification fails and the browser rejects the connection.

---

## 8. Chain of Trust & Intermediate CAs

The CA's **private key must be kept as far from the internet as possible.** If a root CA's private key is ever **compromised**, every company relying on that CA is exposed.

> Example: **HelloFresh, Y Combinator, Discord** all rely on Cybertrust. A leaked private key would let attackers intercept and decrypt users' credit cards, emails, addresses, etc.

**Solution:** Don't sign with the root directly. Use an **Intermediate CA** (e.g. **Cloudflare** is an intermediate for **Cybertrust**). This keeps the precious **root private key offline**.

### The certificate chain

```
┌─────────────────────────────────────────────┐
│ SERVER CERTIFICATE                            │
│   Owner:  hellofresh.com, Berlin              │
│   Issuer: Cloudflare (Intermediate CA)        │  ── validate signature using
└───────────────────┬─────────────────────────┘     Cloudflare's public key
                    │
                    ▼
┌─────────────────────────────────────────────┐
│ INTERMEDIATE CERTIFICATE                      │
│   Owner:  Cloudflare                          │
│   Issuer: Cybertrust (Root CA)                │  ── validate signature using
└───────────────────┬─────────────────────────┘     Cybertrust's public key
                    │
                    ▼
┌─────────────────────────────────────────────┐
│ ROOT CERTIFICATE (trusted by the browser)     │
│   Owner:  Cybertrust                          │
│   Issuer: Cybertrust   ◄── SAME as owner      │  ── SELF-SIGNED
│   (signed with its own private key)           │     (owner == issuer proves it)
└─────────────────────────────────────────────┘
```

- Each certificate is validated by fetching the **issuer's public key** and checking the signature.
- The **root certificate is self-signed** — its owner and issuer are identical, and it is signed with its own private key. Browsers trust it inherently.
- **Only after all three certificates in the chain are validated** does the browser establish a secure connection. ✅

---

## 9. Inspecting Certificates in the Browser

You can see all of this on any HTTPS site:

1. Look for the **lock icon** next to the domain → *"Connection is secure."*
2. Click it → *"Certificate is valid"* → view certificate details.
3. Each certificate shows:
   - **Issued to** (e.g. `hellofresh.com`)
   - **Issuing organization** (e.g. Cloudflare)
   - **Issue date** and **expiration date** (every certificate expires, e.g. issued Apr 7, expires Apr 7 the next year)
   - **Subject Public Key Info** — the actual public key + its algorithm
4. Under **Details**, you can walk the full **chain of trust**:
   `hellofresh.com` (server) → `Cloudflare` (intermediate) → `Baltimore Cybertrust Root` (root, self-signed).

---

## Key Takeaways

| Concept                         | One-line summary                                                                                    |
| ------------------------------- | --------------------------------------------------------------------------------------------------- |
| **HTTP**                  | Data travels in the open — anyone on the medium can read it.**Not secure.**                  |
| **HTTPS**                 | HTTP + encryption.**Secure.**                                                                 |
| **Symmetric encryption**  | One key for encrypt + decrypt. Fast, but sharing the key over the network is unsafe.                |
| **Asymmetric encryption** | Public/private key pair; one encrypts, the other decrypts. Used to safely share the symmetric key.  |
| **MITM attack**           | Attacker impersonates the server by supplying their own public key. Defeated by CAs.                |
| **Certificate Authority** | Trusted third party that signs a server's certificate, proving the public key is genuine.           |
| **Chain of trust**        | Server cert → Intermediate CA → Root CA (self-signed). All must validate for a secure connection. |

> **The big picture:** HTTPS combines **symmetric encryption** (fast bulk data) + **asymmetric encryption** (safe key exchange) + **certificate authorities** (identity verification) to deliver confidential, tamper-proof, authenticated communication.
