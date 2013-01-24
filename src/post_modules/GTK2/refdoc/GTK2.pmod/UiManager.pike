//! Constructing menus and toolbars from an XML description.
//! Properties:
//! int add-tearoffs
//! string ui
//!
//!
//!  Signals:
//! @b{actions_changed@}
//! Emitted whenever the actions changes.
//!
//!
//! @b{add_widget@}
//! Emitted for each generated menubar and toolbar, but not for generated
//! popup menus.
//!
//!
//! @b{connect_proxy@}
//! Emitted after connecting a proxy to an action.
//!
//!
//! @b{disconnect_proxy@}
//! Emitted after disconnecting a proxy from an action.
//!
//!
//! @b{post_activate@}
//! Emitted just after the action is activated.
//!
//!
//! @b{pre_activate@}
//! Emitted just before the action is activated.
//! A UI definition:
//! &lt;ui&gt;
//!   &lt;menubar&gt;
//!     &lt;menu name="FileMenu" action="FileMenuAction"&gt;
//!       &lt;menuitem name="New" action="New2Action" /&gt;
//!       &lt;placeholder name="FileMenuAdditions" /&gt;
//!     &lt;/menu>
//!     &lt;menu name="JustifyMenu" action="JustifyMenuAction"&gt;
//!       &lt;menuitem name="Left" action="justify-left"/&gt;
//!       &lt;menuitem name="Centre" action="justify-center"/&gt;
//!       &lt;menuitem name="Right" action="justify-right"/&gt;
//!       &lt;menuitem name="Fill" action="justify-fill"/&gt;
//!     &lt;/menu&gt;
//!   &lt;/menubar&gt;
//!   &lt;toolbar action="toolbar1"&gt;
//!     &lt;placeholder name="JustifyToolItems"&gt;
//!       &lt;separator/&gt;
//!       &lt;toolitem name="Left" action="justify-left"/&gt;
//!       &lt;toolitem name="Centre" action="justify-center"/&gt;
//!       &lt;toolitem name="Right" action="justify-right"/&gt;
//!       &lt;toolitem name="Fill" action="justify-fill"/&gt;
//!       &lt;separator/&gt;
//!     &lt;/placeholder&gt;
//!   &lt;/toolbar&gt;
//! &lt;/ui&gt;
//!
//!

inherit G.Object;

GTK2.UiManager add_ui( int merge_id, string path, string name, string action, int type, int top );
//! Adds a ui element to the current contents.
//! 
//! If type is GTK2.UI_MANAGER_AUTO, GTK2+ inserts a menuitem, toolitem or
//! separator if such an element can be inserted at the place determined by
//! path.  Otherwise type must indicate an element that can be inserted at the
//! place determined by path.
//!
//!

int add_ui_from_file( string filename );
//! Parses a file containing a ui definition.
//!
//!

int add_ui_from_string( string buffer );
//! Parses a string containing a ui definition and merges it with the current
//! contents.  An enclosing &gt;ui&lt; element is added if it is missing.
//!
//!

protected GTK2.UiManager create( mapping|void props );
//! Creates a new ui manager object.
//!
//!

GTK2.UiManager ensure_update( );
//! Makes sure that all pending updates to the ui have been completed.
//!
//!

GTK2.AccelGroup get_accel_group( );
//! Returns the GTK2.AccelGroup associated with this.
//!
//!

GTK2.Action get_action( string path );
//! Looks up an action by following a path.
//!
//!

array get_action_groups( );
//! Returns the list of action groups.
//!
//!

int get_add_tearoffs( );
//! Returns whether menus generated by this manager will have tearoff menu
//! items.
//!
//!

array get_toplevels( int types );
//! Obtains a list of all toplevel widgets of the requested types.  Bitwise or
//! of @[UI_MANAGER_ACCELERATOR], @[UI_MANAGER_AUTO], @[UI_MANAGER_MENU], @[UI_MANAGER_MENUBAR], @[UI_MANAGER_MENUITEM], @[UI_MANAGER_PLACEHOLDER], @[UI_MANAGER_POPUP], @[UI_MANAGER_SEPARATOR], @[UI_MANAGER_TOOLBAR] and @[UI_MANAGER_TOOLITEM].
//!
//!

string get_ui( );
//! Creates a ui definition of the merged ui.
//!
//!

GTK2.Widget get_widget( string path );
//! Looks up a widget by following a path.  The path consists of the names
//! specified in the xml description of the ui, separated by '/'.  Elements
//! which don't have a name or action attribute in the xml (e.g. &gt;popup&lt;)
//! can be addressed by their xml element name (e.g. "popup").  The root element
//! ("/ui") can be omitted in the path.
//! 
//! Note that the widget found be following a path that ends in a &gt;menu&lt;
//! element is the menuitem to which the menu is attached, not the menu itself.
//!
//!

GTK2.UiManager insert_action_group( GTK2.ActionGroup group, int pos );
//! Inserts an action group into the list of action groups.  Actions in
//! earlier groups hide actions with the same name in later groups.
//!
//!

int new_merge_id( );
//! Returns an unused merge id, suitable for use with add_ui().
//!
//!

GTK2.UiManager remove_action_group( GTK2.ActionGroup group );
//! Removes an action group from the list of action groups.
//!
//!

GTK2.UiManager remove_ui( int merge_id );
//! Unmerges the part of the content identified by merge_id.
//!
//!

GTK2.UiManager set_add_tearoffs( int setting );
//! Sets the "add-tearoffs" property, which controls whether menus generated
//! by this manager will have tearoff menu items.
//! 
//! Note that this only affects regular menus.  Generated popup menus never
//! have tearoff menu items.
//!
//!
