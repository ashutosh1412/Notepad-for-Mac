# Generates NativeLanguagesExtra.inc: Notepad++ languages beyond the hand-tuned set,
# with style roles derived from Lexilla's LexicalStyles.iface names.
import re, sys
iface, header, out = sys.argv[1], sys.argv[2], sys.argv[3]
prefix_for = {}
for line in open(iface):
    m = re.match(r'lex (\w+)=(SCLEX_\w+) (SCE_\w+_)', line)
    if m: prefix_for.setdefault(m.group(2), m.group(3))
consts = {}
for line in open(header):
    m = re.match(r'#define (SCE_\w+) (\d+)', line)
    if m: consts[m.group(1)] = int(m.group(2))
lexer_sclex = {}
for line in open(sys.argv[4]):
    name, sclex = line.split()
    lexer_sclex[name] = sclex

def role(suffix):
    s = suffix.upper()
    rules = [('COMMENT', 'comment'), ('DOC', 'comment'), ('ERROR', 'error'), ('BADSTRING', 'error'),
             ('NUMBER', 'number'), ('NUMERIC', 'number'), ('HEX', 'number'), ('DECIMAL', 'number'), ('OCTAL', 'number'), ('BINARY', 'number'),
             ('STRING', 'string'), ('CHARACTER', 'string'), ('CHAR', 'string'), ('VERBATIM', 'string'), ('QUOTE', 'string'), ('HEREDOC', 'string'), ('REGEX', 'string'),
             ('PREPROC', 'preprocessor'), ('DIRECTIVE', 'preprocessor'), ('PRAGMA', 'preprocessor'), ('MACRO', 'preprocessor'), ('DEFINE', 'preprocessor'), ('ATTRIBUTE', 'attribute'),
             ('OPERATOR', 'operator'), ('DELIMITER', 'operator'), ('BRACE', 'operator'),
             ('KEYWORD2', 'keyword2'), ('WORD2', 'keyword2'), ('BUILTIN', 'keyword2'), ('FUNCTION', 'keyword2'), ('TYPE', 'type'), ('CLASS', 'type'),
             ('KEYWORD', 'keyword'), ('WORD', 'keyword'), ('INSTRUCTION', 'keyword'), ('COMMAND', 'keyword'), ('REGISTER', 'keyword2'), ('STATEMENT', 'keyword'),
             ('LABEL', 'tag'), ('TAG', 'tag'), ('SECTION', 'tag'), ('VARIABLE', 'variable'), ('PARAM', 'variable'), ('SYMBOL', 'attribute'), ('KEY', 'attribute'),
             ('ADDRESS', 'number'), ('CHECKSUM', 'preprocessor'), ('RECSTART', 'keyword'), ('RECTYPE', 'keyword'), ('DATA', 'default')]
    for key, value in rules:
        if key in s: return value
    return None

# id, display name, lexer, extensions, keywords (set 0), line comment, block start, block end
languages = [
  ('actionscript', 'ActionScript', 'cpp', 'as mx', 'break case catch class continue default do dynamic else extends false finally for function if implements import in instanceof interface internal is native new null override package private protected public return static super switch this throw true try typeof use var void while with', '//', '/*', '*/'),
  ('ada', 'Ada', 'ada', 'ada ads adb', 'abort abs abstract accept access aliased all and array at begin body case constant declare delay delta digits do else elsif end entry exception exit for function generic goto if in interface is limited loop mod new not null of or others out overriding package pragma private procedure protected raise range record rem renames requeue return reverse select separate some subtype synchronized tagged task terminate then type until use when while with xor', '--', None, None),
  ('asn1', 'ASN.1', 'asn1', 'mib asn1', '', '--', None, None),
  ('asp', 'ASP', 'hypertext', 'asp aspx asax ascx ashx asmx axd', '', None, '<!--', '-->'),
  ('asm', 'Assembly', 'asm', 'asm s inc', 'mov add sub mul div inc dec push pop call ret jmp je jne jz jnz cmp test and or xor not shl shr lea nop int', ';', None, None),
  ('autoit', 'AutoIt', 'au3', 'au3', 'and byref case const continuecase continueloop default dim do else elseif endfunc endif endselect endswitch endwith enum exit exitloop false for func global if in local next not or redim return select static step switch then to true until wend while with', ';', '#cs', '#ce'),
  ('avisynth', 'AviSynth', 'avs', 'avs avsi', 'true false return global function', '#', '/*', '*/'),
  ('baanc', 'BaanC', 'baan', 'bc cln', '', '|', None, None),
  ('blitzbasic', 'Blitzbasic', 'blitzbasic', 'bb', 'and case const data default dim else elseif end endif exit false field for function global gosub goto if include local next not null or read repeat restore return select step then to true type until wend while', ';', None, None),
  ('caml', 'Caml', 'caml', 'ml mli sml thy', 'and as assert begin class constraint do done downto else end exception external false for fun function functor if in include inherit initializer lazy let match method module mutable new object of open or private rec sig struct then to true try type val virtual when while with', None, '(*', '*)'),
  ('cmake', 'CMake', 'cmake', 'cmake', 'add_custom_command add_custom_target add_definitions add_dependencies add_executable add_library add_subdirectory cmake_minimum_required else elseif endforeach endfunction endif endmacro endwhile find_package foreach function if include include_directories install link_directories macro message option project set target_link_libraries while', '#', None, None),
  ('cobol', 'COBOL', 'COBOL', 'cbl cbd cdb cdc cob cpy copy lst', 'accept add call cancel close compute continue delete display divide evaluate exit go goback if initialize inspect merge move multiply open perform read release return rewrite search set sort start stop string subtract unstring write', '*', None, None),
  ('csound', 'CSound', 'csound', 'orc sco csd', '', ';', '/*', '*/'),
  ('coffeescript', 'CoffeeScript', 'coffeescript', 'coffee litcoffee', 'and break by catch class continue delete do else extends false finally for if in instanceof is isnt loop new no not null of off on or return super switch then this throw true try typeof undefined unless until when while yes yield', '#', '###', '###'),
  ('d', 'D', 'd', 'd', 'abstract alias align asm assert auto body bool break byte case cast catch char class const continue dchar debug default delegate delete deprecated do double else enum export extern false final finally float for foreach foreach_reverse function goto if immutable import in inout int interface invariant is lazy long mixin module new nothrow null out override package pragma private protected public pure real ref return scope shared short static struct super switch synchronized template this throw true try typeid typeof ubyte uint ulong union unittest ushort version void wchar while with', '//', '/*', '*/'),
  ('errorlist', 'ErrorList', 'errorlist', '', '', None, None, None),
  ('escseq', 'Escape Sequence (ANSI)', 'escseq', 'ansi', '', None, None, None),
  ('escript', 'ESCRIPT', 'escript', 'src em', 'basic basicio boats cfgfile file http npc os uo util accessible addmenuitem appendconfigfileelem applyconstraint applydamage applyrawdamage assignrecttoweatherregion append baseskilltorawskill boatfromitem broadcast ban cdbl cint cstr checklineofsight checklosat checkskill consumemana consumereagents consumesubstance createaccount createitematlocation if else elseif endif while endwhile for endfor foreach endforeach return var const program endprogram function endfunction use include', '//', '/*', '*/'),
  ('forth', 'Forth', 'forth', 'forth', '', '\\', '(', ')'),
  ('fortran', 'Fortran (free form)', 'fortran', 'f90 f95 f2k f23 f03 f08', 'allocatable allocate assignment associate call case character close common complex contains continue cycle data deallocate default dimension do double else elseif end enddo endif entry enum equivalence exit external format function go goto if implicit in include inout integer intent interface intrinsic logical module namelist none nullify only open operator optional out parameter pause pointer print private procedure program public read real recursive result return rewind save select sequence stop subroutine target then type use where while write', '!', None, None),
  ('fortran77', 'Fortran (fixed form)', 'f77', 'f for f77', 'call character common complex continue data dimension do double else end endif equivalence external format function goto if implicit integer intrinsic logical parameter print program read real return save stop subroutine then write', 'C', None, None),
  ('freebasic', 'Freebasic', 'freebasic', 'bas bi', 'and as byref byval case const declare dim do else elseif end enum exit for function if loop next not or private public return select step sub then to type until wend while', "'", "/'", "'/"),
  ('gdscript', 'GDScript', 'gdscript', 'gd', 'and as assert await break breakpoint class class_name const continue elif else enum export extends false for func if in is match not null onready or pass preload return self setget signal static super tool true var while yield', '#', None, None),
  ('gui4cli', 'Gui4Cli', 'gui4cli', '', '', '//', None, None),
  ('haskell', 'Haskell', 'haskell', 'hs lhs las', 'as case class data default deriving do else hiding if import in infix infixl infixr instance let module newtype of qualified then type where', '--', '{-', '-}'),
  ('hollywood', 'Hollywood', 'hollywood', 'hws', '', ';', '/*', '*/'),
  ('ihex', 'Intel HEX', 'ihex', 'hex', '', None, None, None),
  ('inno', 'Inno Setup', 'inno', 'iss', '', ';', None, None),
  ('json5', 'JSON5', 'json', 'json5', 'true false null', '//', '/*', '*/'),
  ('jsp', 'JSP', 'hypertext', 'jsp', '', None, '<!--', '-->'),
  ('kixtart', 'KIXtart', 'kix', 'kix', '', ';', None, None),
  ('lisp', 'LISP', 'lisp', 'lsp lisp', 'not defun + - * / = < > <= >= princ eval apply funcall quote identity function complement backquote lambda set setq setf defmacro gensym make symbol intern name value plist get getf putprop remprop hash array aref car cdr caar cadr cdar cddr first second third rest last list cons append reverse length nth nthcdr member if when unless cond case let let* progn do loop', ';', '#|', '|#'),
  ('latex', 'LaTeX', 'latex', 'tex sty', '', '%', None, None),
  ('matlab', 'Matlab', 'matlab', 'm', 'break case catch classdef continue else elseif end for function global if otherwise parfor persistent return spmd switch try while', '%', '%{', '%}'),
  ('mssql', 'Microsoft Transact-SQL', 'mssql', 'tsql', 'add all alter and any as asc authorization backup begin between break browse bulk by cascade case check checkpoint close clustered coalesce collate column commit compute constraint contains continue convert create cross current cursor database dbcc deallocate declare default delete deny desc distinct distributed double drop else end errlvl escape except exec execute exists exit external fetch file fillfactor for foreign from full function goto grant group having holdlock identity if in index inner insert intersect into is join key kill left like lineno load merge national nocheck nonclustered not null nullif of off offsets on open option or order outer over percent pivot plan precision primary print proc procedure public raiserror read references replication restore restrict return revert revoke right rollback rowcount rule save schema select set setuser shutdown some statistics table tablesample then to top tran transaction trigger truncate union unique update use user values varying view waitfor when where while with', '--', '/*', '*/'),
  ('mmixal', 'MMIXAL', 'mmixal', 'mms', '', '%', None, None),
  ('nim', 'Nim', 'nim', 'nim', 'addr and as asm bind block break case cast concept const continue converter defer discard distinct div do elif else end enum except export finally for from func if import in include interface is isnot iterator let macro method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type using var when while xor yield', '#', '#[', ']#'),
  ('nncrontab', 'Nncrontab', 'nncrontab', 'tab spf', '', '\\', None, None),
  ('nsis', 'NSIS', 'nsis', 'nsi nsh', 'Function FunctionEnd Section SectionEnd SubSection SubSectionEnd Name OutFile InstallDir Page UninstPage File Delete RMDir CreateDirectory WriteRegStr ReadRegStr Exec ExecWait MessageBox Goto Return Call StrCmp IntCmp IfFileExists SetOutPath', ';', '/*', '*/'),
  ('oscript', 'OScript', 'oscript', 'osx', '', '//', '/*', '*/'),
  ('pascal', 'Pascal', 'pascal', 'pas pp p inc lpr dpr', 'and array asm begin case const constructor destructor div do downto else end except file finally for function goto if implementation in inherited inline interface is label mod nil not object of on or packed procedure program property raise record repeat set shl shr string then threadvar to try type unit until uses var while with xor', '//', '{', '}'),
  ('postscript', 'PostScript', 'ps', 'ps', '', '%', None, None),
  ('properties', 'Properties', 'props', 'properties', '', '#', None, None),
  ('purebasic', 'Purebasic', 'purebasic', 'pb', '', ';', None, None),
  ('r', 'R', 'r', 'r rdata rds rda', 'if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA NA_integer_ NA_real_ NA_character_', '#', None, None),
  ('raku', 'Raku', 'raku', 'raku rakumod rakudoc rakutest p6 pm6 pod6 t6', 'BEGIN CHECK CONTROL END ENTER FIRST INIT KEEP LAST LEAVE NEXT POST PRE QUIT UNDO class constant does else elsif for given grammar has if is last loop method module multi my next our proto redo regex repeat return role rule sub submethod subset token unit unless until when while', '#', None, None),
  ('rebol', 'REBOL', 'rebol', 'r2 r3 reb', '', ';', None, None),
  ('resource', 'Resource file', 'cpp', 'rc', 'ACCELERATORS ALT AUTO3STATE AUTOCHECKBOX AUTORADIOBUTTON BEGIN BITMAP BLOCK BUTTON CAPTION CHARACTERISTICS CHECKBOX CLASS COMBOBOX CONTROL CTEXT CURSOR DEFPUSHBUTTON DIALOG DIALOGEX DISCARDABLE EDITTEXT END EXSTYLE FONT GROUPBOX ICON LANGUAGE LISTBOX LTEXT MENU MENUEX MENUITEM MESSAGETABLE POPUP PUSHBUTTON RADIOBUTTON RCDATA RTEXT SCROLLBAR SEPARATOR SHIFT STATE3 STRINGTABLE STYLE TEXTINCLUDE VALUE VERSION VERSIONINFO VIRTKEY', '//', '/*', '*/'),
  ('sas', 'SAS', 'sas', 'sas', 'data run proc quit set merge by if then else do end output input infile cards datalines format informat label length keep drop rename where retain array', '*', '/*', '*/'),
  ('scheme', 'Scheme', 'lisp', 'scm smd ss', 'and begin case cond define delay do else if lambda let let* letrec or quasiquote quote set! unquote', ';', '#|', '|#'),
  ('smalltalk', 'Smalltalk', 'smalltalk', 'st', 'ifTrue: ifFalse: whileTrue: whileFalse: ifNil: ifNotNil: ifTrue:ifFalse: self super true false nil thisContext', None, '"', '"'),
  ('spice', 'Spice', 'spice', 'scp out', '', '*', None, None),
  ('structuredtext', 'Structured Text', 'fcST', 'st', 'AND ARRAY BY CASE CONST DO ELSE ELSIF END_CASE END_FOR END_FUNCTION END_FUNCTION_BLOCK END_IF END_PROGRAM END_REPEAT END_STRUCT END_TYPE END_VAR END_WHILE EXIT FOR FUNCTION FUNCTION_BLOCK IF MOD NOT OF OR PROGRAM REPEAT RETURN STRUCT THEN TO TYPE UNTIL VAR VAR_GLOBAL VAR_INPUT VAR_OUTPUT WHILE XOR', '//', '(*', '*)'),
  ('srec', 'S-Record', 'srec', 'mot srec', '', None, None, None),
  ('tcl', 'TCL', 'tcl', 'tcl', 'after append array break catch cd close concat continue else elseif eof error eval exec exit expr file flush for foreach format gets glob global if incr info join lappend lindex linsert list llength lrange lreplace lsearch lsort namespace open proc puts pwd read regexp regsub rename return scan seek set source split string subst switch tell time trace unset update uplevel upvar variable vwait while', '#', None, None),
  ('tehex', 'Tektronix extended HEX', 'tehex', 'tek', '', None, None, None),
  ('tex', 'TeX', 'tex', '', '', '%', None, None),
  ('txt2tags', 'txt2tags', 'txt2tags', 't2t', '', '%', None, None),
  ('vb', 'Visual Basic', 'vb', 'vb vbs bas frm cls ctl pag dsr dob', 'and as boolean byref byte byval call case class const continue currency date declare dim do double each else elseif empty end enum error event exit explicit false for friend function get global gosub goto if implements in integer is let lib long loop me mod new next not nothing null object on option optional or private property public redim rem resume return select set single static step stop string sub then to true type typeof until variant wend while with xor', "'", None, None),
  ('visualprolog', 'Visual Prolog', 'visualprolog', 'pro cl i pack ph', 'goal namespace interface class implement open inherits supports resolve delegate monitor constants domains predicates constructors properties clauses facts', '%', '/*', '*/'),
  ('verilog', 'Verilog', 'verilog', 'v sv vh svh', 'always and assign begin buf case casex casez default defparam else end endcase endfunction endmodule endtask for forever function if initial inout input integer module nand negedge nor not or output parameter posedge reg repeat task time wait while wire xor', '//', '/*', '*/'),
  ('vhdl', 'VHDL', 'vhdl', 'vhd vhdl vho', 'access after alias all architecture array assert attribute begin block body buffer bus case component configuration constant disconnect downto else elsif end entity exit file for function generate generic group guarded if impure in inertial inout is label library linkage literal loop map new next null of on open others out package port postponed procedure process pure range record register reject return select severity shared signal subtype then to transport type unaffected units until use variable wait when while with', '--', None, None),
  ('registry', 'Registry', 'props', 'reg', '', ';', None, None),
  ('msdos', 'MS-DOS Style', None, 'nfo', '', None, None, None),
]

def objc(value):
    if value is None: return 'nil'
    return '@"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

lines = ['// Generated by genlang.py from Lexilla LexicalStyles.iface. Do not edit by hand.']
for ident, name, lexer, exts, keywords, line, bstart, bend in languages:
    styles = ''
    if lexer and lexer in lexer_sclex and lexer_sclex[lexer] in prefix_for:
        prefix = prefix_for[lexer_sclex[lexer]]
        groups = {}
        for const, value in consts.items():
            if const.startswith(prefix):
                r = role(const[len(prefix):])
                if r and r != 'default': groups.setdefault(r, []).append(str(value))
        styles = ' '.join(f'{r}:{",".join(sorted(v, key=int))}' for r, v in sorted(groups.items()))
    elif lexer == 'hypertext':
        styles = None
    kw = f'@[{objc(keywords)}]' if keywords else '@[]'
    style_expr = 'kHtmlStyles' if lexer == 'hypertext' else ('kCppStyles' if lexer == 'cpp' else objc(styles))
    lines.append(f'[self language:{objc(ident)} name:{objc(name)} lexer:{objc(lexer)} extensions:{objc(exts)} keywords:{kw} '
                 f'styles:{style_expr} comment:{objc(line)} block:{objc(bstart)} :{objc(bend)}],')
open(out, 'w').write('\n'.join(lines) + '\n')
print(len(languages), 'languages')
