# TLS — Basic Theory

How HTTPS proves you're talking to the real server, agrees on a secret, and encrypts data.

---

## 1. The building block: key pairs

Everyone in PKI (the server, and every Certificate Authority) has a **key pair**:

```
Private Key 🔒  → kept secret
Public  Key 🌍  → given to everyone
```

Rule: what one key locks, only the *other* key can unlock. A **signature** made with a
private key can only be verified with the matching public key.

---

## 2. How a certificate is signed by a CA

A certificate just says *"this public key belongs to google.com"*. To make it trustworthy,
a **Certificate Authority (CA)** signs it.

```
                    CERTIFICATE
                ┌───────────────────┐
                │ Owner: google.com │
                │ Public Key: ABCDEF│
                └───────────────────┘
                          │
              CA hashes the certificate
                          │
                   Hash = 5A8F9C        (a "fingerprint" — change 1 char → totally different hash)
                          │
            CA encrypts the hash with its PRIVATE key
                          │
                    Signature = XYZ987
                          │
                          ▼
                    CERTIFICATE
                ┌───────────────────┐
                │ Owner: google.com │
                │ Public Key: ABCDEF│
                │ Signature: XYZ987 │  ← added
                └───────────────────┘
```

The CA signs **only the hash**, not the whole certificate.

---

## 3. How the browser verifies the certificate

The browser already ships with a **trusted root store** — a built-in address book of CA
public keys (DigiCert, Let's Encrypt / ISRG Root X1, GlobalSign, …). That's how it knows
the CA's public key in advance.

```
   Server sends certificate ──▶ Browser

   ┌─ Hash1: browser hashes the certificate itself ──────────▶ 5A8F9C
   │
   └─ Hash2: browser decrypts the Signature with CA's PUBLIC key ─▶ 5A8F9C

                 Hash1 == Hash2 ?
                 ├── ✅ yes → certificate is genuine & unmodified, trust it
                 └── ❌ no  → reject
```

**Why tampering fails:** if an attacker changes `google.com` → `evil.com`, the browser's
computed hash changes (`8BB123`), but the signature still decrypts to the old `5A8F9C`.
Mismatch → rejected. Only the CA's private key could have produced a signature that verifies
with the CA's public key, so a valid signature proves **authenticity + integrity**.

> Modern CAs often use ECDSA, not RSA. Then the browser doesn't literally "decrypt" the
> signature — it runs a *verify(cert, signature, CA public key) → valid/invalid* algorithm.
> Same idea.

---

## 4. Does the server verify the browser? Usually no.

Normal HTTPS is **one-way TLS**: only the server proves its identity.

```
Browser ──▶ "prove you're my bank"
Server  ──▶ sends certificate
Browser     verifies it ✅
            ... encrypted tunnel established ...
Browser ──▶ username / password / token (sent INSIDE the encrypted tunnel)
Server      authenticates the user
```

The browser never sends a certificate. You're identified by **login**, not by a cert —
because issuing/renewing/revoking a cert for every internet user would be unmanageable.

**Mutual TLS (mTLS)** = both sides present certificates and verify each other (server sends
`CertificateRequest`, client sends its cert + signs a fresh challenge with its private key to
prove it actually *owns* the key, not just copied the cert). Used in **Kubernetes (kubelet ↔
API server)**, service-to-service microservices, corporate VPNs, IoT — not public websites.

| | Normal HTTPS | mTLS |
| --- | --- | --- |
| Browser verifies server | ✅ | ✅ |
| Server verifies client cert | ❌ | ✅ |
| Client needs a certificate | ❌ | ✅ |

---

## 5. Session key & data encryption

Once identity is verified, both sides agree on **one shared symmetric key** and use fast
symmetric crypto (**AES** or **ChaCha20**) for all the actual data. There are two ways they
reach that shared key:

### Old model (RSA key exchange — TLS 1.0–1.2)

```
Browser takes Google's PUBLIC key from the certificate
        │
Browser generates a random session key
        │
Encrypt(session key, Google's public key) ──── internet ────▶ Server
                                                              │
                                          Server decrypts with its PRIVATE key
                                                              │
                        Both now share the same session key → AES/ChaCha20 for all data
```

Your intuition matches this exactly. **Weakness:** if the server's private key is stolen
*later*, an attacker who recorded the traffic can decrypt the old session key — and all past
data.

### Modern model (TLS 1.3 — ECDHE)

The session key is **never sent over the wire**. Both sides exchange *temporary* public keys
and independently compute the same shared secret (Elliptic-Curve Diffie–Hellman Ephemeral):

```
Browser                              Server
temp private A                       temp private B
temp public  A ───── exchange ─────▶ temp public B
       ◀──────────────────────────────────
both compute the SAME shared secret (math; the secret itself never travels)
       │
derive session keys → AES/ChaCha20
```

Here the **certificate is only used to prove identity**: the server *signs* part of the
handshake with its private key, and the browser verifies that signature with the cert's
public key. The temporary keys are thrown away after the connection — so stealing the
server's private key later still can't decrypt old traffic. This is **Forward Secrecy**.

---

## 6. One-line takeaways

- **Certificate** = server's public key + CA signature proving it's authentic.
- **CA verification** = re-hash the cert, compare against the signature decrypted with the
  CA's (pre-trusted) public key.
- **Session key** = one shared symmetric key; old TLS sends it RSA-encrypted, TLS 1.3 derives
  it with ECDHE (never transmitted → forward secrecy).
- **Data** = always encrypted with fast symmetric crypto (AES / ChaCha20).
- Certificate's job in TLS 1.3: **prove identity**, not encrypt the key.
