//! hop's example plugin in Rust: a list ranked by hop, a callback, an instant command.

use hop_plugin::*;
use serde_json::json;
use std::time::{SystemTime, UNIX_EPOCH};

struct Hello {
    name: String,
    shout: bool,
}

impl Hello {
    fn greeting(&self, word: &str) -> String {
        let text = format!("{word}, {}!", self.name);
        if self.shout { text.to_uppercase() } else { text }
    }
}

impl Plugin for Hello {
    fn initialize(&mut self, cx: &mut Context) -> Result<()> {
        self.name = cx.init.string("name").unwrap_or("friend").to_string();
        self.shout = cx.init.bool("shout").unwrap_or(false);
        // An extra root command, beside those in plugin.json5.
        let greeting = self.greeting("Hello");
        cx.root_items(
            vec![Item::new("root-greet", "Copy My Greeting")
                .subtitle(greeting.clone())
                .icon(Icon::symbol("hand.wave"))
                .action(Action::copy("Copy Greeting", greeting))],
            vec![],
        );
        Ok(())
    }

    fn run(&mut self, _cx: &mut Context, command: &str, _query: Option<&str>) -> Result<Response> {
        match command {
            "greet" => {
                let words = [("en", "Hello", "🇬🇧"), ("sl", "Živjo", "🇸🇮"), ("de", "Hallo", "🇩🇪"), ("ja", "Konnichiwa", "🇯🇵")];
                let view = View::list().placeholder("Pick a greeting…").empty_text("No greeting matches").items(
                    words.iter().map(|(code, word, flag)| {
                        let text = self.greeting(word);
                        let item = Item::new(*code, text.clone()).subtitle(format!("in {code}"));
                        let item = if *code == "en" { item.chip("default", "info") } else { item };
                        item
                            .icon(Icon::emoji(*flag))
                            .keywords([*code])
                            .action(Action::copy("Copy Greeting", text.clone()))
                            .action(Action::paste("Paste Greeting", text).shortcut("cmd+return"))
                            .action(Action::callback("Count Letters", "count", json!({ "word": word })).shortcut("cmd+l"))
                            .action(
                                Action::callback("Forget It", "forget", json!({ "word": word }))
                                    .destructive()
                                    .confirm(format!("Forget “{word}”? (Nothing is stored; this shows a confirm screen.)")),
                            )
                    }),
                );
                Ok(Response::view(view))
            }
            "echo" => Ok(Response::view(
                View::list().placeholder("Type something, then ↵").submit().empty_text("↵ sends what you typed"),
            )),
            "time" => {
                let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
                let (h, m) = ((secs / 3600) % 24, (secs / 60) % 60);
                Ok(Response::hud(format!("{h:02}:{m:02} UTC")).dismissing())
            }
            other => Err(Error::new(format!("unknown command {other}"))),
        }
    }

    fn action(&mut self, _cx: &mut Context, _command: &str, id: &str, payload: Option<serde_json::Value>) -> Result<Response> {
        match id {
            "count" => {
                let word = payload.as_ref().and_then(|p| p["word"].as_str()).unwrap_or("");
                Ok(Response::hud(format!("“{word}” has {} letters", word.chars().count())))
            }
            "forget" => Ok(Response::hud("Forgotten").dismissing()),
            other => Err(Error::new(format!("unknown action {other}"))),
        }
    }

    fn submit(&mut self, _cx: &mut Context, _command: &str, text: &str) -> Result<Response> {
        Ok(Response::hud(text.chars().rev().collect::<String>()))
    }

    fn answer(&mut self, _cx: &mut Context, text: &str) -> Result<Option<Answer>> {
        let Some(name) = text.strip_prefix("hello ").map(str::trim).filter(|n| !n.is_empty()) else { return Ok(None) };
        let greeting = format!("Hello, {name}!");
        Ok(Some(Answer {
            title: Some("Greeting".into()),
            items: vec![Item::new("answer", greeting.clone())
                .subtitle("from the Rust example")
                .icon(Icon::symbol("hand.wave.fill"))
                .action(Action::copy("Copy Greeting", greeting))],
        }))
    }

    fn cli(&mut self, _cx: &mut Context, args: &[String], _stdin: Option<&str>) -> Result<CliOutput> {
        let shout = args.iter().any(|a| a == "--shout");
        let name = args.iter().find(|a| !a.starts_with("--")).cloned().unwrap_or_else(|| self.name.clone());
        let text = format!("Hello, {name}!");
        Ok(CliOutput::print(format!("{}\n", if shout || self.shout { text.to_uppercase() } else { text })))
    }
}

fn main() {
    serve(Hello { name: "friend".into(), shout: false });
}
