# ToyTalk user guide

This guide is for parents and caregivers using ToyTalk, without needing to read
logs or developer details.

## The simple flow

1. Open **ToyTalk Hub** on the Mac.
2. Wait until Hub says it is ready.
3. Choose **Local AI** or **Cloud AI**.
4. Set the parent PIN.
5. If using Cloud AI, add a Gemini or OpenAI key.
6. Optional for Cloud AI: turn on **Cloud AI web search** if you want supported
   providers to answer current/live questions.
7. Pair the phone by QR code, or use ToyTalk directly on this Mac.
8. Add a kid profile.
9. Add a toy buddy.
10. Upload a voice sample.
11. Preview and approve the voice.
12. Start playtime.

Keep the Mac awake while a phone or Mac client is using ToyTalk.

## If something feels stuck

Try these in order:

1. Wait a little longer if Hub is still starting. First launch can download and
   prepare voice or AI support.
2. Keep the Mac open, awake, and connected to Wi-Fi.
3. Quit ToyTalk Hub and open it again.
4. On the phone, close and reopen the ToyTalk app.
5. If the phone says it is not paired, pair again from the QR code.
6. If a voice sample fails, try a cleaner recording with less background noise.
7. If the toy does not answer, switch once between Local AI and Cloud AI, then
   switch back to the mode you want.
8. If Hub still shows a setup problem, use **Copy diagnostics** or **Open logs**
   from Hub and share that with a technical helper.

## Common problems

### The phone cannot pair

- Make sure the phone and Mac are on the same Wi-Fi.
- Keep ToyTalk Hub open.
- Show a fresh QR code from Hub and scan it again.
- If Hub says the phone is already paired but the phone disagrees, remove that
  phone from Hub's paired devices and pair again.

### The toy does not talk back

- Make sure Hub is ready.
- Make sure the selected toy has an approved voice.
- Try typing a message instead of using the microphone.
- If typing works but voice does not, the phone microphone or speech-to-text
  permission may need attention.

### The toy voice sounds wrong

- Upload a clearer sample.
- Use one toy voice per character.
- Preview before approving.
- Do not approve a voice that does not sound right.

### The answer feels too slow

ToyTalk has to do several things: understand the text, generate an answer, make
the toy voice, send audio back, and play it. Shorter child prompts and shorter
answers are faster. Local AI can be slower than Cloud AI on some Macs.

### The app asks for parent PIN

ToyTalk uses the parent PIN to protect setup, settings, and starting playtime.
If the PIN is not set, set it in ToyTalk Hub first.

## What stays local

Voice samples, voice profiles, family settings, characters, and conversation
history are stored by ToyTalk Hub on your Mac. In Cloud AI mode, ToyTalk sends
redacted text and a small amount of recent conversation context to the selected
AI provider so it can answer the child naturally.

If Cloud AI web search is on, supported Cloud AI providers may use their own
search/grounding tools for current questions such as today’s weather, scores, or
current office holders. Local AI does not require a search key in the normal app
flow; if a question needs latest information, it asks the child to check with a
grown-up instead of guessing.
