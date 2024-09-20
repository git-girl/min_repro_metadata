use sqlx::{self, PgPool};
pub async fn test(db: &PgPool) {
    // this is a compiled query this should repro
    let x = sqlx::query!("SELECT * FROM some_table;").execute(&db).await.unwrap();
}
