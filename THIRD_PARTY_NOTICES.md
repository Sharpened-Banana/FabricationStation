# Third-party notices

FabricationStation's Midnight profession knowledge table (`Data/GameData_Knowledge.lua`, generated from
`tools/gamedata/sources/skill_lines.csv` and `tools/gamedata/sources/knowledge_sources.csv`) contains game data
(quest IDs, item IDs, item names, knowledge point values and skill line IDs) taken from the MIT-licensed projects
below. Their copyright notices and licence texts follow, as the MIT licence requires. Each CSV row's `credit`
column names the files that row was taken from.

Point values were cross-checked against public guides (method.gg, wow-professions.com, warcraft.wiki.gg) as facts
only; no text or tables were copied from those guides.

The licence texts below are reproduced verbatim (choretracker's line endings converted from CRLF to LF).

## DjinnisDataTexts

- Repository: https://github.com/RobertLCraig/DjinnisDataTexts
- Commit: 32accbfd570ab5554e5c74c80ef7f67500916880
- Copyright: Copyright (c) 2026 Djinni (https://r.craig.ooo)
- Files used: `Modules/Professions/Data.lua`; `Modules/Professions/Data_<Profession>.lua` for Alchemy, Blacksmithing, Enchanting, Engineering, Herbalism, Inscription, Jewelcrafting, Leatherworking, Mining, Skinning, Tailoring.
- What was used: quest IDs, item IDs, item names (in `hint`; including the gathering-drop labels), knowledge point
  values (the only source for them), and the base-to-Midnight skill line IDs.

```text
MIT License

Copyright (c) 2026 Djinni (https://r.craig.ooo)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## choretracker

- Repository: https://github.com/ThingEngineering/choretracker
- Commit: b9131e55b1ae4b60fae31823a254915952242f16
- Copyright: Copyright (c) 2014 Freddie
- Files used: `Data/Chores/Professions/<Profession>.lua` for Alchemy, Blacksmithing, Enchanting, Engineering, Herbalism, Inscription, Jewelcrafting, Leatherworking, Mining, Skinning, Tailoring.
- What was used: quest IDs, item IDs, item names (in `hint`; the weekly treasure names), and the base-to-Midnight
  skill line IDs. No point values.

```text
The MIT License (MIT)

Copyright (c) 2014 Freddie

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## AllTheThings

- Repository: https://github.com/ATTWoWAddon/AllTheThings
- Commit: 5ee014cf4cf4c9e4d4c8f3c0d2333e3ac695ad07
- Copyright: Copyright (c) 2026 AllTheThings WoW Addon
- Files used: `.contrib/.db/standard/10 - Professions/<Profession>.lua` (the Midnight `expansion(EXPANSION.MID` blocks)
  for Alchemy, Blacksmithing, Enchanting, Engineering, Herbalism, Inscription, Jewelcrafting, Leatherworking, Mining, Skinning, Tailoring; `.contrib/.db/standard/00 - Item DB/CharacterItemDB.lua` (the book item-to-quest pairs).
- What was used: quest IDs and item IDs, to confirm the rows taken from the other two sources. No item names, point
  values or skill line IDs.

```text
MIT License

Copyright (c) 2026 AllTheThings WoW Addon

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
