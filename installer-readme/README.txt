*****************************************************************************
  BETA VERSION

  This is a beta version of CS.Coder Block Folding. It is still being tested
  and may have defects. Save your work often while you try it.

  Found a problem? Please report it:
  https://github.com/cscoder69/delphi-block-folding/issues
*****************************************************************************

CS.Coder - Block Folding
========================

Folds statement blocks in the Delphi code editor: if (with its else), for,
while, with, try, case, repeat and, as an option, a begin..end on its own.

Works with Delphi 11, 12 and 13 (32-bit IDE, and the 64-bit IDE of 12 and 13).


INSTALL
  1. Close Delphi.
  2. Double-click Install.bat.
  3. Open Delphi. The commands are in the main menu: CS.Coder > Block Folding.

  It installs for every supported Delphi found on this Windows user, with no
  administrator rights. Running Install.bat again updates to the version in
  this folder and keeps your settings.

HOW TO USE
  Ctrl+Alt+B         folds the block around the cursor; on the first line of
                     a folded block, opens it
  Ctrl+Alt+Shift+B   opens every fold made in the current unit
  Mouse              when the IDE's own code folding is turned off, - and +
                     signs are drawn beside the code to fold and open

  CS.Coder > Block Folding > Configuracoes... changes the shortcuts, the kinds
  of block and the text shown on a folded line. Folds last while the unit
  stays open: editing around them and saving keeps them; closing and
  reopening the unit brings it back unfolded.

UNINSTALL
  1. Close Delphi.
  2. Double-click Uninstall.bat.

  Your settings are kept. To delete them as well, run:  Uninstall.bat /data

WHERE THINGS ARE
  Packages:   %LOCALAPPDATA%\CSCoder\BlockFolding\bin
  Settings:   Windows registry, one set per Delphi version:
              HKEY_CURRENT_USER\Software\Embarcadero\BDS\<version>\CSCoder\BlockFolding
  Log:        %LOCALAPPDATA%\CSCoder\BlockFolding\diagnostico.log  (what the
              plugin did, for support; it never leaves your computer)

LANGUAGE
  The About window follows the language of Windows (English, Portuguese,
  Spanish, German or French). The menu and the settings window are in
  Portuguese in this version.

LICENSE
  Open source, MIT License. See LICENSE.txt.
