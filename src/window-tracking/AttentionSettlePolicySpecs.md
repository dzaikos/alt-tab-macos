# Attention settle — Specs

The rule that decides which of an app's accessibility answers reaches `AttentionModel`. Pure: arrivals in,
a deadline and a verdict out. `AttentionEngine` owns the timer and calls this.

## Why it exists

An app raising all of its windows answers once per window, 29ms apart (#5974, measured). Every answer is
true and the user went nowhere — the app puts keys back where they started. Committing each one walked the
app's whole set to the top of the MRU, seen live. Taking only the LAST answer per process is right for that
case and for a genuine switch alike, so the rule is "wait until the app stops talking", and it needs nothing
guessed in advance and taken back.

Since the attention rework this is **the only thing standing between a multi-answer burst and a scrambled
order** — no other rule looks at runs of events any more.

## The rule

- an answer supersedes whatever that process had pending, **including its deadline** — otherwise a run
  commits `settle` after its FIRST member rather than after its last
- a deadline is identified by the arrival that armed it, so a timer left over from a superseded answer
  commits nothing
- state is per process: one app's burst never delays another app's answer
- a process exit drops its pending answer, so a reused pid inherits nothing

`settle` is 60ms, a little over the measured 29ms spacing. Widening it delays every genuine switch by the
same amount, against a 219ms floor for the fastest human action ever captured; raises spaced wider than it
commit separately and #5974's shape returns (live QA watches that in amber).

## Test scenarios

- **testARunOfAnswersCommitsOnceWithTheLastWindow** — #5974's shape: four answers 29ms apart collapse to one
  commit, naming the window the run ended on.
- **testASupersededTimerCommitsNothing** — the timer from an overtaken answer fires and is refused; without
  this the run commits once per member after all.
- **testTheDeadlineIsPushedBackByEachAnswer** — the deadline follows the LAST answer, not the first, which is
  what makes a run collapse instead of committing mid-burst.
- **testAQuietAnswerCommitsItself** — one answer with nothing after it is not a burst and commits normally.
- **testTwoAppsSettleIndependently** — a talkative app does not hold up a quiet one's answer.
- **testAProcessExitDropsItsPendingAnswer** — and a reused pid inherits nothing.
