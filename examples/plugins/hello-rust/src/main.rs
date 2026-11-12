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
        Ok(())
    }

    fn run(&mut self, _cx: &mut Context, command: &str, _query: Option<&str>) -> Result<Response> {
        match command {
            "greet" => {
                let words = [("en", "Hello", "🇬🇧"), ("sl", "Živjo", "🇸🇮"), ("de", "Hallo", "🇩🇪"), ("ja", "Konnichiwa", "🇯🇵")];
                let view = View::list().placeholder("Pick a greeting…").empty_text("No greeting matches").items(
                    words.iter().map(|(code, word, flag)| {
                        let text = self.greeting(word);
                        Item::new(*code, text.clone())
                            .subtitle(format!("in {code}"))
                            .icon(Icon::emoji(*flag))
                            .keywords([*code])
                            .action(Action::copy("Copy Greeting", text.clone()))
                            .action(Action::paste("Paste Greeting", text).shortcut("cmd+return"))
                            .action(Action::callback("Count Letters", "count", json!({ "word": word })).shortcut("cmd+l"))
                    }),
                );
                Ok(Response::view(view))
            }
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
            other => Err(Error::new(format!("unknown action {other}"))),
        }
    }
}

fn main() {
    serve(Hello { name: "friend".into(), shout: false });
}
