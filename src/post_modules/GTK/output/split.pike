// Output one file per class as C, more or less.
inherit "util";
string head = "", sfhead="", dir, sdir;
string debug = "";
object parent;

static string filename( Class c )
{
  if( strlen( c->c_name() ) )
    return "p"+c->c_name()+".c";
  return "pgtk_globals.c";
}

array files = ({});
static void output_class( Class cls, int lvl )
{
  string current_data = "";

  if( !cls->functions["_sprintf"] )
    cls->create_default_sprintf();

  /* Start output */
  current_data += "#define EXTPRG extern\n"+sfhead;
  if( sizeof( cls->pre ) )
    current_data += COMPOSE( cls->pre );
  void output_thing( object thing )
  {
    if( mixed err=catch( current_data += thing->c_defenition() ) )
      werror(thing->file+":"+thing->line+": Error: "+
             (stringp(err)?err:describe_backtrace(err))+"\n" );
  };

  foreach( sort( indices( cls->functions ) ), string fun )
    output_thing( cls->functions[ fun ] );

  foreach( sort( indices( cls->members ) ), string mem )
    output_thing( cls->members[ mem  ] );

  // Processing done. Actually write the file.
  write_file( dir + filename( cls ), current_data );
  files += ({ filename( cls ) });
}

string protos = "";

static void build_protos( Class cls, int lvl )
{
  if( cls->name != "global" )
    protos+=("  "*lvl)+"EXTPRG struct program *p"+cls->c_name()+"_program;\n";
  foreach( sort( indices( cls->functions ) ), string f )
    protos += ("  "*lvl)+ " extern "+cls->functions[ f ]->c_prototype();
  foreach( sort( indices( cls->members ) ), string f )
    protos += ("  "*lvl)+ " extern "+cls->members[ f ]->c_prototype();
}

int init_n;
string initfun = "", exitfun="", type_switch="", toplevel ="";
static void build_pike_fadds( Class cls, int lvl )
{
  string res = "";
  init_n++;

  if( mixed e = catch
  {
    void output_thing( mixed thing )
    {
      if( mixed err=catch( res += thing->pike_add() ) )
        werror(thing->file+":"+thing->line+": Error: "+
               (stringp(err)?err:describe_backtrace(err))+"\n" );
    };

    if( cls->name != "_global" )
    {
      exitfun += "  free_program( p"+cls->c_name()+"_program );\n";
      type_switch +=
                  "#ifdef "+cls->c_type_define()+"\n"
                  "  if(PGTK_CHECK_TYPE(widget, "+cls->c_type_define()+"))\n"
                  "     return p"+cls->c_name()+"_program;\n"
                  "#endif\n";
    }
    res = "static void _"+init_n+"()\n{\n";

    if( cls->name != "_global" )
    {
      res +=
          "   start_new_program(); /* "+cls->name+" */\n";
      if( cls->inherits )
        res += "  low_inherit( p"+cls->inherits->c_name()+
            "_program,0,0,0,0,0);\n";
      else
      {
        res += "  ADD_STORAGE(struct object_wrapper);\n";
        res += "  set_init_callback(pgtk_clear_obj_struct);\n";
      }
    }

    foreach( sort( indices( cls->functions ) ), string f )
      output_thing( cls->functions[ f ] );
    foreach( sort( indices( cls->members ) ), string f )
      output_thing( cls->members[ f ] );
    if( cls->name != "_global" )
      res += ("  add_program_constant("+S(cls->pike_name(),1,0,26)+",\n"
              "                       (p"+cls->c_name()+
              "_program = end_program()), 0);\n");
    res += "}\n\n";
    toplevel += res;
  } )
    werror(cls->file+":"+cls->line+": Error: "+
           (stringp(e)?e:describe_backtrace(e))+"\n" );

}

string make_initfun()
{
  string res = "";
  string line = "";
  for( int i = 1; i<=init_n; i++ )
  {
    line += "_"+i+"(); ";
    if( strlen( line ) > 70 )
    {
      res += "  "+line+"\n";
      line = "";
    }
  }
  if( strlen(line) )
    res += "  "+line+"\n";
  return res;
}
void post_class_build()
{
}

array(string) output( mapping(string:Class) classes,
                      mapping(string:Constant) constants,
                      array(Node) global_code )
{
  head = Stdio.read_bytes( combine_path( sdir, "../pgtk.c.head" ) );
  sfhead = replace( head, "PROTOTYPES", "#include <prototypes.h>" );
  traverse_class_tree( classes, output_class );
  post_class_build();
  traverse_class_tree( classes, build_protos );
  write_file( dir + "prototypes.h",  protos );
  write_file( dir + "time_stamp", (string)time() );

  string pre = "#define EXTPRG\n"+sfhead+"\n", res = "";
  
  pre += Parser.Pike.simple_reconstitute( global_code );

  foreach( sort(indices(constants)), string c )
    if( mixed e = catch( initfun += constants[c]->pike_add()) )
      werror(constants[c]->file+":"+constants[c]->line+": Error: "+
             (stringp(e)?e:describe_backtrace(e))+"\n" );



  array q = ({});
  foreach( values(classes), object c )
    q |= indices(c->functions) | indices(c->members);
  q = Array.uniq( q ); sort(map(q,strlen),q);
  foreach( reverse(q), string w ) S(w);
  
  q = Array.uniq(indices(classes)|indices(constants));
  sort(map(q,strlen),q);
  foreach( reverse(q), string w ) S(w,1);

  traverse_class_tree( classes, build_pike_fadds );

  foreach( reverse(q), string w ) S(w);

  mapping done = ([]);
  foreach( values(classes), object c )
    foreach( indices( c->signals) , string s )
      if( !done[s] )
        done[s] = c->signals[s];
  q = indices( done ); sort(map(q,strlen),q);
  foreach( reverse(q), string w ) S("s_"+w,1);
  foreach( values( done ), object t )
    initfun += t->pike_add();
  pre += get_string_data()+"\n\n";
  files = ({ "pgtk.c" }) + files;


  write_file( dir+"pgtk.c",
              pre + toplevel +
              "void pike_module_init() {\n"+make_initfun()+initfun+"}\n\n"
              "void pike_module_exit() {\n"+exitfun+"}\n\n"
              "struct program *pgtk_type_to_program(GtkWidget *widget)\n"
              "{\n"
              +type_switch+
              "  return pgtk_object_program;\n}\n\n" );

  return files;
}

int up_to_date( )
{
  int last_time = (int)Stdio.read_bytes( dir+"time_stamp" );
  if(!last_time )
    return 0;
  foreach( map(get_dir( sdir ), lambda(string s){return sdir+s;})|
           ({ __FILE__, combine_path( __FILE__, "../../new_build_pgtk.pike" )}),
           string f )
  {
    Stdio.Stat s;
    if( !(s = file_stat( f ) ) )
      werror("Failed to stat "+f+"\n");
    if( s->mtime > last_time )
      return 0;
  }
  return 1;
}


void create( string _s, string _d, object p )
{
  sdir = _s;
  dir = _d;
  parent = p;
}

