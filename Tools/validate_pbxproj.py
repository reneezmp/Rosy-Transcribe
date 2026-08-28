"""Checks ScribeDroplet.xcodeproj/project.pbxproj is well formed.

The project file is edited by hand -- cloud sessions have no Xcode -- and a
mistake there is not a compile error, it is an Xcode that refuses to open the
project at all. This parses the OpenStep plist, checks every object reference
resolves and is reachable from the root, and prints each target's sources.

Run from the repository root:

    python3 Tools/validate_pbxproj.py
"""

import re, sys

SRC = open("ScribeDroplet.xcodeproj/project.pbxproj").read()

class P:
    def __init__(s, t): s.t=t; s.i=0
    def ws(s):
        while s.i < len(s.t):
            c = s.t[s.i]
            if c in " \t\r\n": s.i+=1
            elif s.t.startswith("//", s.i):
                j = s.t.find("\n", s.i); s.i = len(s.t) if j<0 else j+1
            elif s.t.startswith("/*", s.i):
                j = s.t.find("*/", s.i)
                if j < 0: raise SyntaxError("unterminated /* at %d" % s.i)
                s.i = j+2
            else: break
    def val(s):
        s.ws()
        c = s.t[s.i]
        if c == "{": return s.dict()
        if c == "(": return s.arr()
        if c == '"': return s.qstr()
        return s.bare()
    def dict(s):
        assert s.t[s.i] == "{"; s.i+=1; d={}
        while True:
            s.ws()
            if s.i>=len(s.t): raise SyntaxError("EOF in dict")
            if s.t[s.i] == "}": s.i+=1; return d
            k = s.val(); s.ws()
            if s.t[s.i] != "=": raise SyntaxError("expected = after key %r at %d" % (k, s.i))
            s.i+=1
            v = s.val(); s.ws()
            if s.t[s.i] != ";": raise SyntaxError("expected ; after key %r at %d" % (k, s.i))
            s.i+=1
            d[k]=v
    def arr(s):
        assert s.t[s.i] == "("; s.i+=1; a=[]
        while True:
            s.ws()
            if s.t[s.i] == ")": s.i+=1; return a
            a.append(s.val()); s.ws()
            if s.t[s.i] == ",": s.i+=1
            elif s.t[s.i] == ")": s.i+=1; return a
            else: raise SyntaxError("expected , or ) at %d" % s.i)
    def qstr(s):
        s.i+=1; out=[]
        while s.t[s.i] != '"':
            if s.t[s.i] == "\\": out.append(s.t[s.i+1]); s.i+=2
            else: out.append(s.t[s.i]); s.i+=1
        s.i+=1; return "".join(out)
    def bare(s):
        m = re.compile(r"[A-Za-z0-9_.$/:\-@+]+").match(s.t, s.i)
        if not m: raise SyntaxError("bad token at %d: %r" % (s.i, s.t[s.i:s.i+30]))
        s.i = m.end(); return m.group(0)

p = P(SRC)
root = p.val()
p.ws()
if p.i != len(SRC): sys.exit("FAIL trailing content at %d" % p.i)
print("PARSE OK")

objs = root["objects"]
ids = set(objs.keys())
print("objects:", len(ids), "| rootObject:", root["rootObject"])

ID = re.compile(r"^[0-9A-F]{24}$")
bad = [i for i in ids if not ID.match(i)]
if bad: sys.exit("FAIL non-24-hex ids: %s" % bad)

refs = set()
def walk(v):
    if isinstance(v, dict):
        for k, x in v.items(): walk(x)
    elif isinstance(v, list):
        for x in v: walk(x)
    elif isinstance(v, str) and ID.match(v): refs.add(v)
walk(root)

missing = sorted(refs - ids)
if missing: sys.exit("FAIL dangling refs: %s" % missing)
print("all %d references resolve" % len(refs))

# reachability from rootObject
seen = set()
def reach(i):
    if i in seen or i not in objs: return
    seen.add(i)
    r = set()
    walk_target = objs[i]
    def w(v):
        if isinstance(v, dict):
            for x in v.values(): w(x)
        elif isinstance(v, list):
            for x in v: w(x)
        elif isinstance(v, str) and ID.match(v): r.add(v)
    w(walk_target)
    for x in r: reach(x)
reach(root["rootObject"])
orphans = sorted(ids - seen)
if orphans: sys.exit("FAIL unreachable objects: %s" % [(o, objs[o].get("isa")) for o in orphans])
print("all objects reachable from rootObject")

# structural sanity
proj = objs[root["rootObject"]]
assert proj["isa"] == "PBXProject", proj["isa"]
for t in proj["targets"]:
    tgt = objs[t]
    print("target:", tgt["name"], "|", tgt["productType"])
    cl = objs[tgt["buildConfigurationList"]]
    names = [objs[c]["name"] for c in cl["buildConfigurations"]]
    print("   configs:", names)
    for ph in tgt["buildPhases"]:
        phase = objs[ph]
        print("   phase:", phase["isa"], "files:", len(phase["files"]))
        for bf in phase["files"]:
            fr = objs[objs[bf]["fileRef"]]
            assert "path" in fr, fr

# deployment target + arch everywhere
for i, o in objs.items():
    if o.get("isa") == "XCBuildConfiguration":
        bs = o["buildSettings"]
        if "MACOSX_DEPLOYMENT_TARGET" in bs:
            print("   %s MACOSX_DEPLOYMENT_TARGET=%s ARCHS=%s ONLY_ACTIVE_ARCH=%s"
                  % (o["name"], bs["MACOSX_DEPLOYMENT_TARGET"], bs.get("ARCHS"), bs.get("ONLY_ACTIVE_ARCH")))
print("STRUCTURE OK")
