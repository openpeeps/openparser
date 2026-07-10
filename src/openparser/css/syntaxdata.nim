import std/[tables, strutils]
import ../json
import ./syntax

const
  propertiesJson* = staticRead("data/properties.json")
  syntaxesJson* = staticRead("data/syntaxes.json")
  typesJson* = staticRead("data/types.json")
  functionsJson* = staticRead("data/functions.json")
  atRulesJson* = staticRead("data/at-rules.json")
  selectorsJson* = staticRead("data/selectors.json")
  unitsJson* = staticRead("data/units.json")

type
  CssSyntaxEntry* = object
    syntax*: string

  CssPropertyDef* = object
    syntax*: string
    inherited*: bool
    groups*: seq[string]
    order*: string
    status*: string
    appliesto*: string
    mdn_url*: string

  CssTypeEntry* = object
    groups*: seq[string]
    status*: string
    mdn_url*: string

  CssFunctionEntry* = object
    syntax*: string
    groups*: seq[string]
    status*: string
    mdn_url*: string

  CssAtRuleDef* = object
    syntax*: string

  CssSelectorEntry* = object
    syntax*: string

  CssUnitEntry* = object
    syntax*: string

  CssData* = object
    properties*: Table[string, CssPropertyDef]
    syntaxes*: Table[string, CssSyntaxEntry]
    types*: Table[string, CssTypeEntry]
    functions*: Table[string, CssFunctionEntry]
    atRules*: Table[string, CssAtRuleDef]
    selectors*: Table[string, CssSelectorEntry]
    units*: Table[string, CssUnitEntry]
    parsedSyntaxes*: Table[string, SyntaxNode]
    parsedProperties*: Table[string, SyntaxNode]

proc loadCssData*(): CssData =
  result.properties = fromJson(propertiesJson, Table[string, CssPropertyDef])
  result.syntaxes = fromJson(syntaxesJson, Table[string, CssSyntaxEntry])
  result.types = fromJson(typesJson, Table[string, CssTypeEntry])
  result.functions = initTable[string, CssFunctionEntry]()
  result.atRules = initTable[string, CssAtRuleDef]()
  result.selectors = initTable[string, CssSelectorEntry]()
  result.units = initTable[string, CssUnitEntry]()
  result.parsedSyntaxes = initTable[string, SyntaxNode]()
  result.parsedProperties = initTable[string, SyntaxNode]()
  for name, entry in result.properties:
    result.parsedProperties[name] = parseSyntax(entry.syntax)
  for name, entry in result.syntaxes:
    result.parsedSyntaxes[name] = parseSyntax(entry.syntax)

proc getSyntax*(data: CssData, name: string): SyntaxNode =
  if data.parsedSyntaxes.hasKey(name):
    data.parsedSyntaxes[name]
  elif data.syntaxes.hasKey(name):
    let node = parseSyntax(data.syntaxes[name].syntax)
    node
  else:
    nil

proc resolveType*(data: CssData, name: string): SyntaxNode =
  let clean = name.strip(leading = false, trailing = true)
  if clean.endsWith(")"):
    let funcName = clean[0..^2]
    if data.syntaxes.hasKey(funcName):
      return getSyntax(data, funcName)
    return nil
  if data.syntaxes.hasKey(clean):
    return getSyntax(data, clean)
  nil

proc getPropertySyntax*(data: CssData, property: string): SyntaxNode =
  if data.parsedProperties.hasKey(property):
    data.parsedProperties[property]
  elif data.properties.hasKey(property):
    parseSyntax(data.properties[property].syntax)
  else:
    nil
