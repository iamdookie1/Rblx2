#!/usr/bin/env python3
"""
Make an RSA-2048 key pair for the Funky Friday command signing, using only the
Python standard library (no pip installs).

  python make_key.py

It prints two things:
  - PUBLIC n  -> goes in both scripts as LINK_PUB_N (safe to ship/commit)
  - PRIVATE d -> only the dev client needs it. Set it with
                 getgenv().FunkyFridayDevKey = "<d>"  before loadstring,
                 or paste it into LINK_DEV_PRIVATE in the dev's OWN copy.
                 Never share or commit it: whoever has it can command every beta.

The exponent e is always 65537 (0x10001), which the scripts already use, so you
only ever copy n and d. Run it again any time to roll a fresh pair (do it if you
think the private key leaked); then update LINK_PUB_N everywhere.
"""

import random
import sys

rng = random.SystemRandom()


def is_probable_prime(n, k=40):
    if n < 2:
        return False
    for p in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(k):
        a = rng.randrange(2, n - 1)
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def gen_prime(bits):
    while True:
        n = rng.getrandbits(bits) | (1 << (bits - 1)) | 1
        if is_probable_prime(n):
            return n


def egcd(a, b):
    if b == 0:
        return (a, 1, 0)
    g, x, y = egcd(b, a % b)
    return (g, y, x - (a // b) * y)


def inv(a, m):
    g, x, _ = egcd(a % m, m)
    if g != 1:
        raise ValueError("no inverse")
    return x % m


def gen_key(bits=2048):
    e = 65537
    while True:
        p = gen_prime(bits // 2)
        q = gen_prime(bits // 2)
        if p == q:
            continue
        phi = (p - 1) * (q - 1)
        if phi % e == 0:
            continue
        n = p * q
        if n.bit_length() != bits:
            continue
        return n, e, inv(e, phi)


def main():
    print("generating a 2048-bit key (a few seconds)...", file=sys.stderr)
    n, e, d = gen_key()
    print("\nPUBLIC key -> LINK_PUB_N in BOTH scripts (e is already 65537):\n")
    print(format(n, "x"))
    print("\nPRIVATE key -> only the dev client, via")
    print('getgenv().FunkyFridayDevKey = "..."  (keep it secret, never commit):\n')
    print(format(d, "x"))
    print()


if __name__ == "__main__":
    main()
