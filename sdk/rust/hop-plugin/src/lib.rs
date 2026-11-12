//! Write [hop](https://github.com/pseudobun/hop) plugins in Rust.
//!
//! A plugin is a program hop starts on demand. It reads JSON-RPC requests from stdin, one per
//! line, and answers on stdout. hop draws everything: a plugin only describes lists, grids and
//! actions with the types in this crate. See `docs/plugins.md` in the hop repository.
//!
//! ```no_run
//! use hop_plugin::*;
//!
//! struct Hello;
//!
//! impl Plugin for Hello {
//!     fn run(&mut self, _cx: &mut Context, command: &str, _query: Option<&str>) -> Result<Response> {
//!         match command {
//!             "greet" => Ok(Response::view(View::list().item(
//!                 Item::new("hi", "Hello").action(Action::copy("Copy", "Hello")),
//!             ))),
//!             _ => Err(Error::new(format!("unknown command {command}"))),
//!         }
//!     }
//! }
//!
//! fn main() { hop_plugin::serve(Hello) }
//! ```

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::{self, BufRead, Write};

/// The protocol version this crate speaks.
pub const PROTOCOL_VERSION: u32 = 1;

/// An error shown to the user as a failed HUD.
#[derive(Debug, Clone)]
pub struct Error(pub String);

impl Error {
    pub fn new(message: impl Into<String>) -> Self {
        Error(message.into())
    }
}

impl<E: std::error::Error> From<E> for Error {
    fn from(e: E) -> Self {
        Error(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

// MARK: - Views

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ViewKind {
    #[default]
    List,
    Grid,
}

/// Who ranks the items as the user types.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Filtering {
    /// hop ranks them; the plugin hears nothing (fast, the default).
    #[default]
    Hop,
    /// Every change goes to [`Plugin::query`].
    Plugin,
}

/// A list or a grid of items, in sections.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    #[serde(rename = "type")]
    pub kind: ViewKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    pub filtering: Filtering,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub columns: Option<u32>,
    pub sections: Vec<Section>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub empty_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub loading: Option<bool>,
}

impl View {
    pub fn list() -> Self {
        View::default()
    }

    /// Large glyphs (emoji icons) in `columns` columns.
    pub fn grid(columns: u32) -> Self {
        View { kind: ViewKind::Grid, columns: Some(columns), ..View::default() }
    }

    pub fn title(mut self, title: impl Into<String>) -> Self {
        self.title = Some(title.into());
        self
    }

    pub fn placeholder(mut self, text: impl Into<String>) -> Self {
        self.placeholder = Some(text.into());
        self
    }

    pub fn filtering(mut self, filtering: Filtering) -> Self {
        self.filtering = filtering;
        self
    }

    pub fn empty_text(mut self, text: impl Into<String>) -> Self {
        self.empty_text = Some(text.into());
        self
    }

    pub fn loading(mut self, loading: bool) -> Self {
        self.loading = Some(loading);
        self
    }

    pub fn section(mut self, section: Section) -> Self {
        self.sections.push(section);
        self
    }

    /// Adds an item to the last untitled section (creating it).
    pub fn item(mut self, item: Item) -> Self {
        match self.sections.last_mut() {
            Some(s) if s.title.is_none() => s.items.push(item),
            _ => self.sections.push(Section { title: None, items: vec![item] }),
        }
        self
    }

    pub fn items(self, items: impl IntoIterator<Item = Item>) -> Self {
        items.into_iter().fold(self, |v, i| v.item(i))
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Section {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub items: Vec<Item>,
}

impl Section {
    pub fn new(title: impl Into<String>) -> Self {
        Section { title: Some(title.into()), items: vec![] }
    }

    pub fn item(mut self, item: Item) -> Self {
        self.items.push(item);
        self
    }
}

/// A row (or grid cell). `actions[0]` runs on ↵; the rest are in the action panel (⌘K).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accessory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keywords: Option<Vec<String>>,
    pub actions: Vec<Action>,
}

impl Item {
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        Item { id: id.into(), title: title.into(), ..Item::default() }
    }

    pub fn subtitle(mut self, text: impl Into<String>) -> Self {
        self.subtitle = Some(text.into());
        self
    }

    pub fn icon(mut self, icon: Icon) -> Self {
        self.icon = Some(icon);
        self
    }

    pub fn accessory(mut self, text: impl Into<String>) -> Self {
        self.accessory = Some(text.into());
        self
    }

    pub fn keywords(mut self, words: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.keywords = Some(words.into_iter().map(Into::into).collect());
        self
    }

    pub fn action(mut self, action: Action) -> Self {
        self.actions.push(action);
        self
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Icon {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub emoji: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

impl Icon {
    /// An SF Symbol on a tile in the plugin's colour.
    pub fn symbol(name: impl Into<String>) -> Self {
        Icon { symbol: Some(name.into()), ..Icon::default() }
    }

    /// An SF Symbol on a tile in `color` ("#rrggbb").
    pub fn tile(name: impl Into<String>, color: impl Into<String>) -> Self {
        Icon { symbol: Some(name.into()), color: Some(color.into()), ..Icon::default() }
    }

    pub fn emoji(emoji: impl Into<String>) -> Self {
        Icon { emoji: Some(emoji.into()), ..Icon::default() }
    }

    /// An image file, absolute or relative to the plugin folder.
    pub fn file(path: impl Into<String>) -> Self {
        Icon { file: Some(path.into()), ..Icon::default() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActionKind {
    Copy,
    Paste,
    Open,
    OpenFile,
    Reveal,
    Push,
    Callback,
}

/// What an item does. hop runs everything but `callback`, which comes back to
/// [`Plugin::action`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Action {
    pub title: String,
    #[serde(rename = "type")]
    pub kind: ActionKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub view: Option<Box<View>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shortcut: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructive: Option<bool>,
}

impl Action {
    fn of(kind: ActionKind, title: impl Into<String>) -> Self {
        Action {
            title: title.into(),
            kind,
            value: None,
            url: None,
            path: None,
            view: None,
            id: None,
            payload: None,
            shortcut: None,
            destructive: None,
        }
    }

    pub fn copy(title: impl Into<String>, value: impl Into<String>) -> Self {
        Action { value: Some(value.into()), ..Self::of(ActionKind::Copy, title) }
    }

    pub fn paste(title: impl Into<String>, value: impl Into<String>) -> Self {
        Action { value: Some(value.into()), ..Self::of(ActionKind::Paste, title) }
    }

    pub fn open(title: impl Into<String>, url: impl Into<String>) -> Self {
        Action { url: Some(url.into()), ..Self::of(ActionKind::Open, title) }
    }

    pub fn open_file(title: impl Into<String>, path: impl Into<String>) -> Self {
        Action { path: Some(path.into()), ..Self::of(ActionKind::OpenFile, title) }
    }

    pub fn reveal(title: impl Into<String>, path: impl Into<String>) -> Self {
        Action { path: Some(path.into()), ..Self::of(ActionKind::Reveal, title) }
    }

    pub fn push(title: impl Into<String>, view: View) -> Self {
        Action { view: Some(Box::new(view)), ..Self::of(ActionKind::Push, title) }
    }

    /// Calls [`Plugin::action`] with `id` and `payload`.
    pub fn callback(title: impl Into<String>, id: impl Into<String>, payload: Value) -> Self {
        Action { id: Some(id.into()), payload: Some(payload), ..Self::of(ActionKind::Callback, title) }
    }

    /// "cmd+c", "cmd+shift+return".
    pub fn shortcut(mut self, keys: impl Into<String>) -> Self {
        self.shortcut = Some(keys.into());
        self
    }

    pub fn destructive(mut self) -> Self {
        self.destructive = Some(true);
        self
    }
}

// MARK: - Responses

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HudStyle {
    Info,
    Success,
    Warn,
    Fail,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Hud {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub style: Option<HudStyle>,
}

/// What hop does after a request: show a view, push one, pop, flash a HUD, hide.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub view: Option<View>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub push: Option<View>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pop: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hud: Option<Hud>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dismiss: Option<bool>,
}

impl Response {
    pub fn none() -> Self {
        Response::default()
    }

    pub fn view(view: View) -> Self {
        Response { view: Some(view), ..Response::default() }
    }

    pub fn push(view: View) -> Self {
        Response { push: Some(view), ..Response::default() }
    }

    pub fn pop() -> Self {
        Response { pop: Some(true), ..Response::default() }
    }

    pub fn hud(text: impl Into<String>) -> Self {
        Response { hud: Some(Hud { text: text.into(), style: None }), ..Response::default() }
    }

    pub fn fail(text: impl Into<String>) -> Self {
        Response { hud: Some(Hud { text: text.into(), style: Some(HudStyle::Fail) }), ..Response::default() }
    }

    /// Also hide the launcher.
    pub fn dismissing(mut self) -> Self {
        self.dismiss = Some(true);
        self
    }
}

// MARK: - The plugin

/// What hop sends when it starts the program.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Init {
    pub protocol_version: u32,
    pub hop_version: String,
    #[serde(rename = "pluginID")]
    pub plugin_id: String,
    /// Settings by preference id, defaults and Keychain secrets filled in.
    pub preferences: HashMap<String, Value>,
    /// A folder to keep files in.
    pub data_dir: String,
    /// "dark" or "light".
    pub appearance: String,
}

impl Init {
    pub fn string(&self, key: &str) -> Option<&str> {
        self.preferences.get(key).and_then(Value::as_str)
    }

    pub fn bool(&self, key: &str) -> Option<bool> {
        self.preferences.get(key).and_then(Value::as_bool)
    }

    pub fn number(&self, key: &str) -> Option<f64> {
        self.preferences.get(key).and_then(Value::as_f64)
    }
}

/// Talks back to hop outside a reply: update the open view, flash a HUD.
pub struct Context {
    pub init: Init,
}

impl Context {
    /// Replaces the open view of `command` (for work that finishes after the reply).
    pub fn render(&mut self, command: &str, view: View) {
        let mut params = serde_json::to_value(Response::view(view)).unwrap_or(Value::Null);
        if let Value::Object(map) = &mut params {
            map.insert("command".into(), Value::String(command.into()));
        }
        send(&json!({"jsonrpc": "2.0", "method": "render", "params": params}));
    }

    pub fn hud(&mut self, text: impl Into<String>) {
        send(&json!({"jsonrpc": "2.0", "method": "hud", "params": Hud { text: text.into(), style: None }}));
    }

    pub fn loading(&mut self, on: bool) {
        send(&json!({"jsonrpc": "2.0", "method": "loading", "params": {"loading": on}}));
    }
}

/// Implement what you need; `run` is the only required method.
pub trait Plugin {
    /// hop started the program; preferences are in `cx.init`.
    fn initialize(&mut self, _cx: &mut Context) -> Result<()> {
        Ok(())
    }

    /// A command from `plugin.json5` was opened or run. `query` is the text after its prefix.
    fn run(&mut self, cx: &mut Context, command: &str, query: Option<&str>) -> Result<Response>;

    /// The search text changed in a view with [`Filtering::Plugin`].
    fn query(&mut self, _cx: &mut Context, _command: &str, _text: &str) -> Result<Response> {
        Ok(Response::none())
    }

    /// A `callback` action ran.
    fn action(&mut self, _cx: &mut Context, _command: &str, _id: &str, _payload: Option<Value>) -> Result<Response> {
        Ok(Response::none())
    }
}

fn send(message: &Value) {
    let mut out = io::stdout().lock();
    let _ = serde_json::to_writer(&mut out, message);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}

fn str_param<'a>(params: &'a Map<String, Value>, key: &str) -> &'a str {
    params.get(key).and_then(Value::as_str).unwrap_or("")
}

/// Answers hop's requests until stdin closes or hop says `shutdown`.
pub fn serve<P: Plugin>(mut plugin: P) {
    let mut cx = Context { init: Init::default() };
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(request) = serde_json::from_str::<Value>(&line) else { continue };
        let id = request.get("id").cloned();
        let method = request.get("method").and_then(Value::as_str).unwrap_or("");
        let empty = Map::new();
        let params = request.get("params").and_then(Value::as_object).unwrap_or(&empty);
        let result: Result<Value> = match method {
            "initialize" => {
                cx.init = serde_json::from_value(Value::Object(params.clone())).unwrap_or_default();
                plugin.initialize(&mut cx).map(|_| json!({"protocolVersion": PROTOCOL_VERSION}))
            }
            "run" => {
                let query = params.get("query").and_then(Value::as_str);
                plugin.run(&mut cx, str_param(params, "command"), query).map(to_value)
            }
            "query" => plugin.query(&mut cx, str_param(params, "command"), str_param(params, "text")).map(to_value),
            "action" => plugin
                .action(&mut cx, str_param(params, "command"), str_param(params, "id"), params.get("payload").cloned())
                .map(to_value),
            "shutdown" => break,
            other => Err(Error::new(format!("unknown method {other}"))),
        };
        let Some(id) = id else { continue };
        match result {
            Ok(value) => send(&json!({"jsonrpc": "2.0", "id": id, "result": value})),
            Err(Error(message)) => send(&json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": message}})),
        }
    }
}

fn to_value(response: Response) -> Value {
    serde_json::to_value(response).unwrap_or(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn view_serializes_like_hop_reads_it() {
        let v = View::list()
            .title("T")
            .item(Item::new("a", "A").icon(Icon::symbol("star")).action(Action::copy("Copy", "x").shortcut("cmd+c")));
        let json = serde_json::to_value(Response::view(v)).unwrap();
        assert_eq!(json["view"]["type"], "list");
        assert_eq!(json["view"]["filtering"], "hop");
        assert_eq!(json["view"]["sections"][0]["items"][0]["actions"][0]["type"], "copy");
        assert_eq!(json["view"]["sections"][0]["items"][0]["actions"][0]["shortcut"], "cmd+c");
        assert!(json.get("hud").is_none());
    }

    #[test]
    fn action_kinds_are_camel_case() {
        let a = Action::open_file("Open", "/tmp/x");
        assert_eq!(serde_json::to_value(a).unwrap()["type"], "openFile");
    }

    #[test]
    fn init_reads_hop_keys() {
        let init: Init = serde_json::from_value(json!({
            "protocolVersion": 1, "hopVersion": "0.2.0", "pluginID": "dev.x.y",
            "preferences": {"name": "Bunny"}, "dataDir": "/tmp", "appearance": "dark"
        }))
        .unwrap();
        assert_eq!(init.plugin_id, "dev.x.y");
        assert_eq!(init.string("name"), Some("Bunny"));
    }
}
