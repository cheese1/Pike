#pike __REAL_VERSION__

//! A namespace aware version of Parser.XML.Tree. This implementation
//! does as little validation as possible, so e.g. you can call your
//! namespace xmlfoo without complaints.

inherit Parser.XML.Tree;

//! Namespace aware node.
class NSNode {
  inherit Node;

  // New stuff

  /* static */ string default_ns;
  static mapping(string:string) nss;
  static string element_ns;
  static mapping(string:mapping(string:string)) ns_attrs = ([]);

  //! Returns the namespace in which the current element is defined in.
  string get_ns() { return element_ns; }

  //! Returns the default namespace in the current scope.
  string get_default_ns() { return default_ns; }

  //! Returns a mapping with all the namespaces defined in the current
  //! scope, except the default namespace.
  //! @note
  //!   The returned mapping is the same as the one in the node, so
  //!   destructive changes will affect the node.
  mapping(string:string) get_defined_nss() {
    return nss;
  }

  //! @decl mapping(string:string) get_ns_attributes(string namespace)
  //! Returns the attributes in this node that is declared in the provided
  //! namespace.

  //! @decl mapping(string:mapping(string:string)) get_ns_attributes()
  //! Returns all the attributes in all namespaces that is associated with
  //! this node.
  //! @note
  //!   The returned mapping is the same as the one in the node, so
  //!   destructive changes will affect the node.

  mapping(string:string)|mapping(string:mapping(string:string))
    get_ns_attributes(void|string namespace) {
    if(namespace)
      return ns_attrs[namespace] || ([]);
    return ns_attrs;
  }

  //! Adds a new namespace to this node. The preferred symbol to
  //! use to identify the namespace can be provided in the @[symbol]
  //! argument. If @[chain] is set, no attempts to overwrite an
  //! already defined namespace with the same identifier will be made.
  void add_namespace(string ns, void|string symbol, void|int(0..1) chain) {
    if(!symbol)
      symbol = make_prefix(ns);
    if(chain && nss[symbol])
      return;
    if(nss[symbol]==ns)
      return;
    nss[symbol] = ns;
    get_children()->add_namespace(ns, symbol, 1);
  }

  //! Returns the difference between this nodes and its parents namespaces.
  mapping(string:string) diff_namespaces() {
    mapping res = ([]);
    if(!nss) return res;
    foreach(nss; string sym; string ns)
      if(nss[sym]!=ns)
	res[sym]=nss[sym];
  }

  static string make_prefix(string ns) {
    // FIXME: Cache?
    return String.string2hex(Crypto.MD5->hash(ns))[..10];
  }

  //! Returns the element name as it occurs in xml files. E.g.
  //! "zonk:name" for the element "name" defined in a namespace
  //! denoted with "zonk". It will look up a symbol for the namespace
  //! in the symbol tables for the node and its parents. If none is
  //! found a new label will be generated by hashing the namespace.
  string get_xml_name() {
    if(element_ns==default_ns) return mTagName;
    string prefix = search(nss, element_ns);
    if(!prefix)
      prefix = make_prefix(element_ns);
    return prefix + ":" + mTagName;
  }

  // Override old stuff

  void create(int type, string name, mapping attr, string text,
	      void|NSNode parent) {

    // Get the parent namespace context.
    if(parent) {
      parent->add_child(this);
      nss = parent->get_defined_nss();
      default_ns = parent->get_default_ns();
    }
    else
      nss = ([]);

    if(type == XML_TEXT || type == XML_COMMENT) {
      ::create(type, name, attr, text);
      return;
    }

    // First handle all xmlns attributes.
    foreach(attr; string name; string value) {

      // Update namespace scope. Must be done before analyzing the namespace
      // of the current element.
      string lcname = lower_case(name);
      if(lcname=="xmlns") {
	default_ns = value;
	m_delete(attr, name);
      }
      else if(has_prefix(lcname, "xmlns:")) {
	nss = nss + ([ name[6..]:value ]); // No destructive changes.
	continue;
      }
    }

    // Assign the right namespace to this element
    if(has_value(name, ":")) {
      sscanf(name, "%s:%s", element_ns, name);
      if(!nss[element_ns])
	error("Unknown namespace %s.\n", element_ns);
      element_ns = nss[element_ns];
    }
    else
      element_ns = default_ns;

    // Then take care of the rest of the attributes.
    foreach(attr; string name; string value) {

      if(has_prefix(lower_case(name), "xmlns"))
	continue;

      // Move namespaced attributes to a mapping of their own.
      string ns, m;
      if( sscanf(name, "%s:%s", ns, m)==2 ) {
	if(!nss[ns])
	  error("Unknown namespace %s.\n", ns);
	ns = nss[ns];
	m_delete(attr, name);
      } else {
	// FIXME: This makes the RDF-tests work,
	//        but is it according to the spec?
	ns = element_ns;
	m = name;
	if (ns_attrs[ns] && !zero_type(ns_attrs[ns][m])) {
	  // We have an explicit entry already,
	  // so skip the implicit entry.
	  continue;
	}
      }
      if(!ns_attrs[ns])
	ns_attrs[ns] = ([]);
      ns_attrs[ns][m] = value;
    }

    ::create(type, name, attr, text);
  }

  void set_parent(NSNode parent) {
    nss = parent->get_defined_nss() + diff_namespaces();
    ::set_parent(parent);
  }

  NSNode add_child(NSNode c) {
    c->set_parent(this);
    return ::add_child(c);
  }

  //! @decl void remove_child(NSNode child)
  //! The remove_child is a not updated to take care of name
  //! space issues. To properly remove all the parents name spaces
  //! from the chid, call @[remove_node] in the child.

  void remove_node() {
    nss = diff_namespaces();
    ::remove_node();
  }

  NSNode clone(void|int(-1..1) direction) {
    Node n = NSNode(get_node_type(), get_ns()+":"+get_tag_name(),
		    get_attributes(), get_text(), mParent);

    if(direction!=1) {
      Node p = get_parent();
      if(p)
	n->set_parent( p->clone(-1) );
    }

    if(direction!=-1)
      foreach(get_children(), Node child)
	n->add_child( child->clone(1) );

    return n;
  }

  string render_xml()
  {
    String.Buffer data = String.Buffer();
	
    walk_preorder_2(
		    lambda(Node n) {
		      switch(n->get_node_type()) {

		      case XML_TEXT:
                        data->add( text_quote(n->get_text()) );
			break;

		      case XML_ELEMENT:
			if (!sizeof(n->get_tag_name()))
			  break;

			data->add("<", n->get_xml_name());

			if (mapping attr = n->get_attributes()) { // FIXME
                          foreach(indices(attr), string a)
                            data->add(" ", a, "='",
				      attribute_quote(attr[a]), "'");
			}
			/*
			mapping attr = n->get_ns_attrubutes();
			if(sizeof(attr)) {
			  foreach(attr; string ns; mapping attr) {
			  }
			}
			*/
			if (n->count_children())
			  data->add(">");
			else
			  data->add("/>");
			break;
		      }
		    },

		    lambda(Node n) {
		      if (n->get_node_type() == XML_ELEMENT)
			if (n->count_children())
			  if (sizeof(n->get_tag_name()))
			    data->add("</", n->get_xml_name(), ">");
		    });
	
    return (string)data;
  }

  string _sprintf(int t) {
    if(t=='O') {
      mapping nt = ([ XML_ROOT:"ROOT",
		      XML_ELEMENT:"ELEMENT",
		      XML_TEXT:"TEXT",
		      XML_HEADER:"HEADER",
		      XML_PI:"PI",
		      XML_COMMENT:"COMMENT",
		      XML_DOCTYPE:"DOCTYPE",
		      XML_ATTR:"ATTR" ]);
      string n = get_any_name();
      if(!n || !sizeof(n))
	return sprintf("%O(%s)", this_program,
		       nt[get_node_type()] || "UNKNOWN");
      return sprintf("%O(%s,%O,%O)", this_program,
		     nt[get_node_type()] || "UNKNOWN", n, get_ns());
    }
  }
}

static NSNode|int(0..0) parse_xml_callback(string type, string name,
					   mapping attr, string|array contents,
					   mixed location, mixed ...extra)
{
  NSNode node;
  NSNode parent = sizeof(extra[0]) && extra[0]->top();

  switch (type) {
  case "":
  case "<![CDATA[":
    //  Create text node
    return NSNode(XML_TEXT, "", 0, contents, parent);

  case "<!--":
    //  Create comment node
    return NSNode(XML_COMMENT, "", 0, contents, parent);

  case "<?xml":
    //  XML header tag
    return NSNode(XML_HEADER, "", attr, "", parent);

  case "<?":
    //  XML processing instruction
    return NSNode(XML_PI, name, attr, contents, parent);

  case "<>":
    //  Create new tag node.
    return NSNode(XML_ELEMENT, name, attr, "", parent);

  case "<":
    // Create tree node for this contaier.
    extra[0]->push( NSNode(XML_ELEMENT, name, attr, "", parent) );
    return 0;

  case ">":
    return extra[0]->pop();
	
    //  We need to merge consecutive text
    //  children since two text elements can't be neighbors according to
    //  the W3 spec.
    // FIXME: When does this happen?

  case "error":
    if (location && mappingp(location))
      error(contents + " [Offset: " + location->location + "]\n");
    else
      error(contents + "\n");

  case "<!DOCTYPE":
  default:
    return 0;
  }
}

//! Takes a XML string @[data] and produces a namespace node tree.
//! If @[default_ns] is given, it will be used as the default namespace.
//! @throws
//!   Throws an @[error] when an error is encountered during XML
//!   parsing.
NSNode parse_input(string data, void|string default_ns)
{
  object xp = spider.XML();
  Node mRoot;
  
  xp->allow_rxml_entities(1);
  
  // Construct tree from string
  mRoot = NSNode(XML_ROOT, "", ([ ]), "");
  mRoot->default_ns = default_ns;
  ADT.Stack s = ADT.Stack();
  s->push(mRoot);
  xp->parse(data, parse_xml_callback, s);
  return mRoot;
}

//! Makes a visualization of a node graph suitable for
//! printing out on a terminal.
//!
//! @example
//!   > object x = parse_input("<a><b><c/>d</b><b><e/><f>g</f></b></a>");
//!   > write(visualize(x));
//!   Node(ROOT)
//!     NSNode(ELEMENT,"a")
//!       NSNode(ELEMENT,"b")
//!         NSNode(ELEMENT,"c")
//!         NSNode(TEXT)
//!       NSNode(ELEMENT,"b")
//!         NSNode(ELEMENT,"e")
//!         NSNode(ELEMENT,"f")
//!           NSNode(TEXT)
//!   Result 1: 201
//!
string visualize(Node n, void|string indent) {
  if(!indent)
    return sprintf("%O\n", n) + visualize(n, "  ");

  string ret = "";
  foreach(n->get_children(), Node c) {
    ret += sprintf("%s%O\n", indent, c);
    ret += visualize(c, indent+"  ");
  }
  return ret;
}
