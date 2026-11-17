# Decisions

An agent raises a decision by writing `.tmp/decisions/D<n>.json` in its
worktree. The watcher validates it, records it on the task, and sends it to
you. Your answer is written beside it as `D<n>.answer.json`, and goes to the
builder as a prompt when it's free.

## D&lt;n&gt;.json

```json
{
  "id": "D1",
  "question": "Should retries cover 4xx responses?",
  "why": "The issue says retry failed webhooks; a 4xx usually means the receiver rejected the payload.",
  "options": [
    { "label": "5xx and timeouts only", "detail": "Rejected payloads fail at once and show in the log." },
    { "label": "Every non-2xx", "detail": "Simpler, but a bad payload is sent 5 times." }
  ],
  "recommend": 0,
  "mode": "provisional",
  "meanwhile": "Building with 5xx and timeouts only."
}
```

| Field | Rule |
| --- | --- |
| `id` | `D` and a number, the same as the file's name |
| `question` | required |
| `why` | optional; one or two sentences |
| `options` | 2 to 5; each `{ label, detail? }` or a plain string. A label is a button: 60 characters at most, no two alike |
| `recommend` | the index of the recommended option, from 0 |
| `mode` | `provisional` (the default: the agent keeps going on its recommendation) or `blocking` (the agent writes `DECISION D<n>` to its status and stops) |
| `meanwhile` | optional; what the agent does until it's answered |

A file that breaks a rule isn't sent. The builder is told what's wrong, and
the watcher picks the file up once it's fixed.

## D&lt;n&gt;.answer.json

```json
{ "id": "D1", "choice": 1, "label": "Every non-2xx", "text": "but cap it at 3", "by": "you", "via": "rex-inbox", "at": "2026-11-17T14:05:51Z" }
```

| Field | Meaning |
| --- | --- |
| `choice`, `label` | the option picked (index from 0) and its label. With no option, `label` is "Another answer" and `text` is the answer |
| `text` | anything you added |
| `via` | `rex-inbox` or `cli` |
| `stood` | `true` when nobody answered and the recommendation stood, because the plan was approved |

## Replies

A rex-inbox reply carries the button pressed and any words. Words alone
work too: `2`, `2, but cap it at 3`, `Every non-2xx`, or a sentence that is
none of the options, which is taken as your own answer. A number that
starts a sentence ("3 attempts is plenty") is words, not option 3.

Gates read replies the same way, with their own options: a plan with only
words means Revise, a preview with only words means Needs work, and a PR
with only words means Needs changes.
