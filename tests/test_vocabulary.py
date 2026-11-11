#!/usr/bin/env python3
"""Exercise vocabulary layers using the app's Config in the compiled harness."""
import os
import subprocess
import sys

directory = sys.argv[1]
vocabulary = os.path.join(directory, "vocabulary.txt")
source = os.path.join(directory, "layers.swift")
binary = os.path.join(directory, "layers")
subprocess.run([sys.executable, "mkharness.py", "../swift-cli", vocabulary, source], check=True)
subprocess.run(["swiftc", "-O", source, "-o", binary], check=True)
os.makedirs(os.path.join(directory, "work"))


def write(name, text):
    with open(os.path.join(directory, name), "w", encoding="utf-8") as file:
        file.write(text)


def corrected():
    output = subprocess.run([binary], input="correct\tcase\tcommonword userword legacyword alphaword betaword\n",
                            capture_output=True, text=True, check=True).stdout.strip()
    return output.split("\t", 1)[1]


write("common.txt", "COMMON = commonword\n")
write("user.txt", "USER = userword\n")
write("vocabulary.txt", "LEGACY = legacyword\n")
write("work/alpha.txt", "ALPHA = alphaword\n")
write("work/beta.txt", "BETA = betaword\n")
assert corrected() == "COMMON USER LEGACY alphaword betaword"
write("active-work.txt", "alpha\n")
assert corrected() == "COMMON USER legacyword ALPHA betaword"
write("active-work.txt", "beta\n")
assert corrected() == "COMMON USER legacyword alphaword BETA"
write("active-work.txt", "../vocabulary\n")
assert corrected() == "COMMON USER legacyword alphaword betaword"
write("active-work.txt", "\n")
assert corrected() == "COMMON USER legacyword alphaword betaword"
print("vocabulary layers: ok")