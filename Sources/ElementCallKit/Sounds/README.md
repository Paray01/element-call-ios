# Call sounds

Element Call web's own files, copied unchanged so a call sounds the same on every client in it
(spec 024, R3). Do not re-encode them: the hashes are how a reviewer checks they still match web.

| File | Source | SHA-256 |
| :--- | :--- | :--- |
| `join_call.mp3` | `element-call` `src/sound/join_call.mp3` at ea6f2952a | `2a5e12c8470f6602249577e6c783231d70e80784504bae419a299330bc5a53f8` |
| `left_call.mp3` | `element-call` `src/sound/left_call.mp3` at ea6f2952a | `5f4c529262388c3cae87df5957e9607ac438cba2be08d1b84484adf73c137971` |

The mp3s rather than web's `.ogg` twins because AVFoundation does not decode Ogg Vorbis.
