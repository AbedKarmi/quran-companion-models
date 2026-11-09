# Imam Assistant – Quran recognizer model

Files downloaded on demand by the Imam Assistant app (Settings → Speech recognition → Quran model).

| File | Source |
|---|---|
| `quran-encoder.int8.onnx`, `quran-decoder.int8.onnx`, `quran-tokens.txt` | [tarteel-ai/whisper-tiny-ar-quran](https://huggingface.co/tarteel-ai/whisper-tiny-ar-quran), exported to sherpa-onnx int8 (see `tools/quran_model` in the app repo) |
| `silero_vad.onnx` | Silero VAD, from the sherpa-onnx `asr-models` release |

Publish as release **model-v1** so the app finds them at
`https://github.com/AbedKarmi/imamassistant-models/releases/download/model-v1/<file>`.
The app checks each file's SHA-256 (see `lib/recognition/quran_model.dart`). If a file changes,
publish a new release tag and bump `QuranModel.version` / `baseUrl` in the app.

Check the license of the upstream model before publishing, and credit Tarteel.

## Arabic tafsir books (release `tafsir-books-qc`)

Downloaded on demand by Quran Companion (the tafsir library). Listed with their size and SHA-256 in `tafsir-books.json`; the app checks the SHA-256 before installing.

| File | Book | Source |
|---|---|---|
| `ar_kashshaf_qc.zip` | Al-Kashshaf (Tafsir al-Zamakhshari), Al-Zamakhshari (d. 538 AH); edition: Dar al-Kitab al-'Arabi, Beirut, 3rd edition, 1407 AH, with Ibn al-Munayyir's al-Intisaf and the notes on its hadiths | [Quranpedia.net](https://quranpedia.net) data dumps, version 2026-11-05 |
| `ar_razi_qc.zip` | Mafatih al-Ghayb (al-Tafsir al-Kabir), Fakhr al-Din al-Razi (d. 606 AH); edition: Dar Ihya' al-Turath al-'Arabi, Beirut, 3rd edition, 1420 AH | [Quranpedia.net](https://quranpedia.net) data dumps, version 2026-11-05 |
| `ar_raghib_qc.zip` | Tafsir al-Raghib al-Isfahani, al-Raghib al-Isfahani (d. 502 AH), al-Fatiha to the end of al-Ma'ida (all that survives); edition: Kulliyyat al-Da'wa wa Usul al-Din, Umm al-Qura University, 1422 AH | [Quranpedia.net](https://quranpedia.net) data dumps, version 2026-08-10 |

Republished as a downloadable database under the Quranpedia.net data licence, which asks for credit to Quranpedia.net with a link and the dump version. Built by `tool/tafsir_books/books.py` in the app repository; a rebuild from a newer dump gets a new version and is uploaded with `--clobber`.
