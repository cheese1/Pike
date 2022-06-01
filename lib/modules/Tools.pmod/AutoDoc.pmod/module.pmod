#pike __REAL_VERSION__

// This module contains utility functions for XML creation and
// some other useful stuff common to all the modules.

#include "./debug.h"

protected constant DOC_COMMENT = "//!";

//! Flags affecting autodoc extractor behaviour.
//!
//! @seealso
//!   @[ProcessXML.extractXML()], @[MirarDocParser],
//!   @[Tools.Standalone.extract_autodoc()]
enum Flags {
  FLAG_QUIET = 0,	//! Keep quiet about non-fatal errors.
  FLAG_NORMAL = 1,	//! Normal verbosity.
  FLAG_VERBOSE = 2,	//! Extra verbosity.
  FLAG_DEBUG = 3,	//! Full verbosity.
  FLAG_VERB_MASK = 3,	//! Verbosity mask.
  FLAG_KEEP_GOING = 4,	//! Attempt to keep going after errors.
  FLAG_COMPAT = 8,	//! Attempt to be compatible with old Pike.
  FLAG_NO_DYNAMIC = 16,	//! Reduce the amount of dynamic information
			//! in the generated files (line numbers,
			//! extractor version, extraction time, etc).
}

protected int isDigit(int c) { return '0' <= c && c <= '9'; }

protected int isDocComment(string s) {
  return has_prefix(s, DOC_COMMENT);
}

//FIXME: should it return 0 for keywords ??
protected int isIdent(string s) {
  if (!s || s == "")
    return 0;
  int first = s[0];
  switch(s[0]) {
    case 'a'..'z':
    case 'A'..'Z':
    case '_':
    case '`':
      break;
    default:
      if (s[0] < 128)
        return 0;
  }
  return 1;
}

protected int(0..1) isVersion(string s)
{
  string trailer = "";
  return (sscanf(s, "%*d.%*d%s", trailer) == 3) && (trailer == "");
}

protected int(0..1) isFloat(string s)
{
  int n;
  sscanf(s, "%*[0-9].%*[0-9]%n", n);
  return sizeof(s) && n == sizeof(s);
}

protected string xmlquote(string s) {
  return replace(s, ({ "<", ">", "&" }), ({ "&lt;", "&gt;", "&amp;" }));
}

protected string attributequote(string s) {
  return replace(s, ({ "<", ">", "\"", "'", "&" }),
                 ({ "&lt;", "&gt;", "&#34;", "&#39;", "&amp;" }));
}

protected string writeattributes(mapping(string:string) attrs)
{
  string s = "";
  foreach(sort(indices(attrs || ([]))), string attr)
    s += sprintf(" %s='%s'", attr, attributequote(attrs[attr]));
  return s;
}

protected string opentag(string t, mapping(string:string)|void attributes) {
  return "<" + t + writeattributes(attributes) + ">";
}

protected string closetag(string t) { return "</" + t + ">"; }

protected string xmltag(string t, string|mapping(string:string)|void arg1,
                     string|void arg2)
{
  mapping attributes = mappingp(arg1) ? arg1 : 0;
  string content = stringp(arg1) ? arg1 : stringp(arg2) ? arg2 : 0;
  if (content && content != "")
    return opentag(t, attributes) + content + closetag(t);
  string s = "<" + t + writeattributes(attributes) + "/>";
  return s;
}

//! Class used to keep track of where in the source a piece of
//! documentation originated.
class SourcePosition {
  //!
  string filename;

  //! Range of lines.
  int firstline;
  int lastline;

  //!
  protected void create(string filename, int firstline,
                     int|void lastline)
  {
    if (!firstline) {
      werror("**********************************************************\n");
      werror("* NO FIRST LINE !!!!! \n");
      werror("**********************************************************\n");
      werror("%s", describe_backtrace(backtrace()));
      werror("**********************************************************\n");
      werror("**********************************************************\n");
    }
    this::filename = filename;
    this::firstline = firstline;
    this::lastline = lastline;
  }

  //! @returns
  //!   Returns a copy of the current object.
  SourcePosition copy() {
    return SourcePosition(filename, firstline, lastline);
  }

  protected string|zero _sprintf(int t) {
    if(t!='O') return 0;
    string res = "SourcePosition(File: " + (filename ? filename : "?");
    if (firstline)
      if (lastline)
        res += sprintf(", lines: %d..%d", firstline, lastline);
      else
        res += sprintf(", line: %d", firstline);
    return res + ")";
  }

  //! @returns
  //!   Returns a string with an XML-fragment describing the source position.
  string xml(Flags|void flags) {
    if (flags & FLAG_NO_DYNAMIC) return "";
    mapping(string:string) m = ([]);
    m["file"] = filename || "?";
    if (firstline) m["first-line"] = (string) firstline;
    if (lastline) m["last-line"] = (string) lastline;
    return xmltag("source-position", m);
  }
}

//! Base class for errors generated by the autodoc extraction system.
class AutoDocError (
		    //!
		    SourcePosition position,

		    //! Which part of the autodoc system.
		    string part,

		    //! Error message.
		    string message
		    ) {
  protected string _sprintf(int t) {
    return t=='O' && sprintf("%O(%O, %O, %O)", this_program,
			     position, part, message);
  }
}
