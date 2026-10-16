# Code review — please address each comment

Review r3 of the changes in this repository (branch `feature/x`, HEAD deadbee, submitted 2026-10-16T03:34:12+00:00).

How to read the comments:

- "Line N" refers to the file as it exists in the working tree right now, except under a "Commit" heading.
- Comments marked "on deleted code" are about removed lines; those line numbers refer to the file as of the base ref `main`, unless noted otherwise.
- Each comment quotes the lines it targets (`+`/`-`/space = added/removed/unchanged). If line numbers have drifted since submission, locate the quoted code instead.
- Comments marked "detached" quote code that has since changed; apply their intent to the closest current code.
- A "File comment" applies to its whole file; an "Overall" section applies to the entire change.
- Comments under a "Commit" heading were left on that single commit. Their line numbers refer to the file as of that commit (or its parent, for deleted lines). The code may have changed since: address them in the current code, and don't rewrite history unless asked.
- A commit marked "no longer in history" was rewritten (e.g. by a rebase); locate the quoted code instead.

## Overall

Overall thoughts.  

Second para.

## (unknown file)

**Line 1**

>  x

no file

## src/a.swift

**Line 1 (detached)**

>  x

detached new

**Line 2**

>  x

float line

**Line 4 (on deleted code)**

> -gone

deleted base

**Lines 5–6 (on deleted code, as of commit fedcba9)**

> -g1
> -g2

deleted other base

**Line 7 (on code removed since review r2, detached)**

since baseline

## src/b.swift

**File comment**

file-level

**Lines 10–12**

> +x
>  y
> -z

first

earlier reply

later reply

## Commit `4444444`

### src/w.swift

**Line 1**

unknown commit

## Commit `2222222` — Earlier commit

### src/y.swift

**Line 1 (on deleted code)**

> -q

old on commit 2

### src/z.swift

**File comment**

file on commit 2

## Commit `1111111` — Later commit

### src/z.swift

**Line 3**

> +k

on commit 1

commit reply

## Commit `3333333` (no longer in history)

### src/z.swift

**Lines 1–2**

> +g

gone commit
