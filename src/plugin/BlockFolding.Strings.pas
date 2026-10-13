unit BlockFolding.Strings;

// Texts of the plugin in five languages: one id per text and one table with the
// five translations. The language is the one of Windows, English when Windows is
// in a language that is not one of the five. Spanish, German and French were not
// reviewed by a native speaker.
//
// A new text: its id in the enumeration and, in the same position, its line in
// the table.

interface

type
  TFoldLang = (lgEnglish, lgPortuguese, lgSpanish, lgGerman, lgFrench);

  TFoldStr = (
    sTitle,
    // "About" window
    sAboutCaption, sAboutBy, sAboutTagline, sAboutVersionLabel, sAboutBuild, sAboutCompat,
    sAboutLicFree, sAboutLicSub, sAboutLicType, sAboutLicTypeValue, sAboutLicCommercial,
    sAboutAllowed, sAboutLicSource, sAboutSourceOpen, sAboutLicData, sAboutNone,
    sAboutLicenseDetails, sAboutUpdates, sAboutCheckUpdates, sAboutLicenseTitle, sBtnClose,
    sFeatBlockTitle, sFeatBlockText, sFeatKeysTitle, sFeatKeysText, sFeatKeepTitle, sFeatKeepText,
    sFeatDelphiTitle, sFeatDelphiText,
    sAboutSlogan, sAboutSupport, sAboutReport, sAboutRights);

function L(Id: TFoldStr): string; overload;
// Same, run through Format.
function L(Id: TFoldStr; const Args: array of const): string; overload;
function FoldLanguage: TFoldLang;
procedure SetFoldLanguage(Lang: TFoldLang);

implementation

uses System.SysUtils, Winapi.Windows;

const
  LB = sLineBreak;

  Texts: array[TFoldStr, TFoldLang] of string = (
    { sTitle } ('Block Folding', 'Block Folding', 'Block Folding', 'Block Folding', 'Block Folding'),

    { sAboutCaption } ('About Block Folding', 'Sobre o Block Folding', 'Acerca de Block Folding', 'Über Block Folding',
      'À propos de Block Folding'),
    { sAboutBy } ('by', 'por', 'por', 'von', 'par'),
    { sAboutTagline } ('Fold if, for, while, try, case and other statement blocks right in the Delphi code editor.',
      'Dobre blocos if, for, while, try, case e outros direto no editor de código do Delphi.',
      'Pliegue bloques if, for, while, try, case y otros directamente en el editor de código de Delphi.',
      'Falten Sie if-, for-, while-, try-, case- und andere Blöcke direkt im Delphi-Code-Editor.',
      'Pliez les blocs if, for, while, try, case et autres directement dans l''éditeur de code Delphi.'),
    { sAboutVersionLabel } ('Version', 'Versão', 'Versión', 'Version', 'Version'),
    { sAboutBuild } ('Build', 'Build', 'Compilación', 'Build', 'Build'),
    { sAboutCompat } ('Compatibility', 'Compatibilidade', 'Compatibilidad', 'Kompatibilität', 'Compatibilité'),

    { sAboutLicFree } ('Open source', 'Código aberto', 'Código abierto', 'Open Source', 'Code ouvert'),
    { sAboutLicSub } ('Free to use, change and share', 'Livre para usar, alterar e compartilhar',
      'Libre para usar, modificar y compartir', 'Frei zum Nutzen, Ändern und Weitergeben',
      'Libre d''utiliser, de modifier et de partager'),
    { sAboutLicType } ('License type', 'Tipo de licença', 'Tipo de licencia', 'Lizenztyp', 'Type de licence'),
    { sAboutLicTypeValue } ('MIT License', 'Licença MIT', 'Licencia MIT', 'MIT-Lizenz', 'Licence MIT'),
    { sAboutLicCommercial } ('Commercial use', 'Uso comercial', 'Uso comercial', 'Kommerzielle Nutzung',
      'Usage commercial'),
    { sAboutAllowed } ('Allowed', 'Permitido', 'Permitido', 'Erlaubt', 'Autorisé'),
    { sAboutLicSource } ('Source code', 'Código-fonte', 'Código fuente', 'Quellcode', 'Code source'),
    { sAboutSourceOpen } ('Open, may be changed', 'Aberto, pode modificar', 'Abierto, modificable',
      'Offen, veränderbar', 'Ouvert, modifiable'),
    { sAboutLicData } ('Data collection', 'Coleta de dados', 'Recopilación de datos', 'Datenerfassung',
      'Collecte de données'),
    { sAboutNone } ('None', 'Nenhuma', 'Ninguna', 'Keine', 'Aucune'),
    { sAboutLicenseDetails } ('License details', 'Detalhes da licença', 'Detalles de la licencia',
      'Lizenzdetails', 'Détails de la licence'),
    { sAboutUpdates } ('Updates', 'Atualizações', 'Actualizaciones', 'Updates', 'Mises à jour'),
    { sAboutCheckUpdates } ('Check for updates', 'Verificar atualizações', 'Buscar actualizaciones',
      'Nach Updates suchen', 'Rechercher des mises à jour'),
    { sAboutLicenseTitle } ('License', 'Licença', 'Licencia', 'Lizenz', 'Licence'),
    { sBtnClose } ('Close', 'Fechar', 'Cerrar', 'Schließen', 'Fermer'),

    { sFeatBlockTitle } ('Statement blocks', 'Blocos de comandos', 'Bloques de código', 'Anweisungsblöcke',
      'Blocs d''instructions'),
    { sFeatBlockText } ('if, for, while, with, try, case, repeat', 'if, for, while, with, try, case, repeat',
      'if, for, while, with, try, case, repeat', 'if, for, while, with, try, case, repeat',
      'if, for, while, with, try, case, repeat'),
    { sFeatKeysTitle } ('Your shortcuts', 'Seus atalhos', 'Sus atajos', 'Ihre Tastenkürzel', 'Vos raccourcis'),
    { sFeatKeysText } ('Fold and open from the keyboard', 'Dobre e abra pelo teclado', 'Pliegue y abra con el teclado',
      'Falten und öffnen per Tastatur', 'Pliez et ouvrez au clavier'),
    { sFeatKeepTitle } ('Folds that stay', 'Dobras que ficam', 'Pliegues estables', 'Bleibende Faltungen',
      'Des plis qui restent'),
    { sFeatKeepText } ('Kept while you edit the unit', 'Mantidas enquanto você edita a unit',
      'Se mantienen mientras edita la unit', 'Bleiben beim Bearbeiten der Unit', 'Conservés pendant l''édition de l''unité'),
    { sFeatDelphiTitle } ('Made for Delphi', 'Feito para Delphi', 'Hecho para Delphi', 'Für Delphi gemacht',
      'Conçu pour Delphi'),
    { sFeatDelphiText } ('Inside the code editor', 'Dentro do editor de código', 'Dentro del editor de código',
      'Direkt im Code-Editor', 'Dans l''éditeur de code'),

    { sAboutSlogan } ('Code with PURPOSE. Solutions with INTELLIGENCE.',
      'Código com PROPÓSITO. Soluções com INTELIGÊNCIA.',
      'Código con PROPÓSITO. Soluciones con INTELIGENCIA.',
      'Code mit SINN. Lösungen mit INTELLIGENZ.',
      'Du code avec un BUT. Des solutions avec INTELLIGENCE.'),
    { sAboutSupport } ('Support and documentation', 'Suporte e documentação', 'Soporte y documentación',
      'Support und Dokumentation', 'Support et documentation'),
    { sAboutReport } ('Report a problem', 'Avisar de um problema', 'Informar de un problema', 'Ein Problem melden',
      'Signaler un problème'),
    { sAboutRights } ('%s is a product of %s.' + LB + 'Open source under the MIT License.',
      '%s é um produto da %s.' + LB + 'Código aberto sob a licença MIT.',
      '%s es un producto de %s.' + LB + 'Código abierto bajo la licencia MIT.',
      '%s ist ein Produkt von %s.' + LB + 'Open Source unter der MIT-Lizenz.',
      '%s est un produit de %s.' + LB + 'Code ouvert sous licence MIT.'));

var
  Current: TFoldLang;

function WindowsLanguage: TFoldLang;
begin
  case GetUserDefaultUILanguage and $3FF of // primary language id
    $16: Result := lgPortuguese;
    $0A: Result := lgSpanish;
    $07: Result := lgGerman;
    $0C: Result := lgFrench;
  else
    Result := lgEnglish;
  end;
end;

function L(Id: TFoldStr): string;
begin
  Result := Texts[Id, Current];
end;

function L(Id: TFoldStr; const Args: array of const): string;
begin
  Result := Format(Texts[Id, Current], Args);
end;

function FoldLanguage: TFoldLang;
begin
  Result := Current;
end;

procedure SetFoldLanguage(Lang: TFoldLang);
begin
  Current := Lang;
end;

initialization
  Current := WindowsLanguage;

end.
