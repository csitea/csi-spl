# How to post

...

## 7. Polls: answer a question with a click

A question in a post is a ```poll fence. The fence is the form: one per message (a second fence in the same body stays a code block). A form holds one or more questions: a line that is not an option starts the next question, its options follow.

- `(A) text` options make a radio form (pick one per question).
- `[A] text` options make a checkbox form (pick any).
- A form is all radios or all checkboxes, never both (a mixed fence is not a form and stays a code block).

The answer is a normal reply in the poll's topic, posted by the click (radio, fire and forget) or when a checkbox form locks in (45 s per question after the first click, or its Send). Its lines are the machine-readable marker:

```
Poll: <msg_id>                the form's message
Answer: A — Deploy now        one question (checkbox: `A,C — x; y`, `none`)
Answer 2: B — Later           a form of several questions, one line each
Chat: wants to discuss        "Chat about this": text follows
```

Each answer reply carries the sender's whole current form; the newest one of a sender is that sender's answer (re-answer replaces).

### A question that waits on the owner's go
A question that waits on the owner's go is a poll with **one option `(GO) Go`**; never "Reply go".

Example:
````markdown
```poll
Ready to deploy?
(GO) Go
```
````

The WUI renders this as a **Go button**; a click posts `Answer: GO — Go`.

```
Poll: <msg_id>
Answer: GO — Go
```