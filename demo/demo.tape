# cctreeline demo tape — generates the README GIF.
#
# Install vhs once:   brew install vhs        (or https://github.com/charmbracelet/vhs)
# Then, from the repo root:   vhs demo/demo.tape   →   writes demo/cctreeline.gif
#
# demo/demo.sh renders the statusline against an isolated temp git repo + seeded
# generic caches — no real credentials are read and no API call is made.

Output demo/cctreeline.gif

Require bash
Require git

Set Shell bash
Set Theme "Dracula"     # swap for "Catppuccin Mocha", "TokyoNight", etc. if you prefer
Set FontSize 18
Set Width 1040
Set Height 380
Set Padding 28
Set TypingSpeed 55ms

Sleep 500ms
Type "bash demo/demo.sh"
Sleep 500ms
Enter
Sleep 4500ms
