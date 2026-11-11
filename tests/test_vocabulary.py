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


def corrected(folder=None):
    request = "correct\tcase\tcommonword userword legacyword alphaword betaword" + (f"\t{folder}" if folder else "")
    output = subprocess.run([binary], input=request + "\n", capture_output=True, text=True, check=True).stdout.strip()
    return output.split("\t", 1)[1]


def harness(lines):
    output = subprocess.run([binary], input="".join(l + "\n" for l in lines), capture_output=True, text=True,
                            check=True).stdout
    return dict(line.split("\t", 1) for line in output.splitlines())


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

# The project of the folder the text goes to adds its own corrections; an unknown folder, or one without a work file,
# gets the shared ones only, and another project's never apply.
write("active-work.txt", "beta\n")
assert corrected("/Users/me/appl/alpha") == "COMMON USER legacyword ALPHA BETA"
assert corrected("/Users/me/appl/gamma") == "COMMON USER legacyword alphaword BETA"
assert corrected("-") == "COMMON USER legacyword alphaword BETA"
os.remove(os.path.join(directory, "active-work.txt"))
assert corrected("/Users/me/appl/alpha/") == "COMMON USER LEGACY ALPHA betaword"
# A spelling both define is read the project's way there, and the shared way elsewhere.
write("work/alpha.txt", "ALPHA = alphaword\nPROJECT = legacyword\n")
assert corrected("/Users/me/appl/alpha") == "COMMON USER PROJECT ALPHA betaword"
assert corrected("/Users/me/appl/beta") == "COMMON USER LEGACY alphaword BETA"

# The app and scripts/learn_edits.py name a project's work file alike.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import learn_edits  # noqa: E402
folders = ["/Users/me/appl/worktree/p3.2-defect", "/Users/me/s1_design_spec/", "/x/ชื่อไทย", "/x/a b+c", "/x/kebab-case_1"]
names = harness(f"project\t{i}\t{f}" for i, f in enumerate(folders))
assert [names[str(i)] for i in range(len(folders))] == [learn_edits.project_name(f) for f in folders], names
print("vocabulary layers: ok")