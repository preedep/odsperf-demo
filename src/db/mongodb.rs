use mongodb::{Client, Database};
use tracing::info;

pub async fn connect(uri: &str, db_name: &str) -> anyhow::Result<Database> {
    info!("connecting to MongoDB...");

    let client = Client::with_uri_str(uri).await?;

    // Smoke-test: ping the database
    client
        .database(db_name)
        .run_command(bson::doc! { "ping": 1 })
        .await?;

    info!("MongoDB connected");
    Ok(client.database(db_name))
}
