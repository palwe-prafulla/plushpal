#![forbid(unsafe_code)]

use std::{collections::HashMap, fmt};

use plushpal_core_domain::AgeBand;
use rusqlite::{params, Connection, OpenFlags};

pub type TimestampSeconds = i64;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct CharacterId(pub String);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SessionId(pub String);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct VoiceAssetId(pub String);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SecretRef(pub String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HistoryPolicy {
    SessionOnly,
    RetainDays(u16),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CharacterRecord {
    pub id: CharacterId,
    pub alias: String,
    pub voice_asset_id: Option<VoiceAssetId>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CharacterProfileRecord {
    pub record: CharacterRecord,
    pub traits_json: String,
    pub parent_guidance: Option<String>,
    pub enabled: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoiceAssetRecord {
    pub id: VoiceAssetId,
    pub character_id: CharacterId,
    pub encrypted_path: String,
    pub wrapped_key_ref: SecretRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionRecord {
    pub id: SessionId,
    pub character_id: CharacterId,
    pub age_band: AgeBand,
    pub started_at: TimestampSeconds,
    pub ended_at: Option<TimestampSeconds>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TurnRecord {
    pub session_id: SessionId,
    pub child_text: String,
    pub character_text: String,
    pub completed_at: TimestampSeconds,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryTurnRecord {
    pub child_text: String,
    pub character_text: String,
    pub completed_at: TimestampSeconds,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExternalTurnProjection {
    pub age_band: AgeBand,
    pub child_text: String,
    pub character_text: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeletionPhase {
    DestroyWrappedKeys,
    DeleteContent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeletionJournal {
    pub character_id: CharacterId,
    pub phase: DeletionPhase,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct StorageState {
    characters: HashMap<CharacterId, CharacterRecord>,
    voices: HashMap<VoiceAssetId, VoiceAssetRecord>,
    sessions: HashMap<SessionId, SessionRecord>,
    turns: Vec<TurnRecord>,
    deletion: Option<DeletionJournal>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StorageError {
    Duplicate,
    NotFound,
    DeletionAlreadyActive,
    InvalidRetentionDays,
    InjectedFailure,
    VaultUnavailable,
    EncryptionUnavailable,
    UnsupportedSchema,
    MigrationFailed,
    InvalidData,
}

pub struct SecretMaterial(Vec<u8>);

impl SecretMaterial {
    #[must_use]
    pub fn new(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub fn expose(&self) -> &[u8] {
        &self.0
    }
}

impl fmt::Debug for SecretMaterial {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretMaterial([REDACTED])")
    }
}

impl Drop for SecretMaterial {
    fn drop(&mut self) {
        self.0.fill(0);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Migration {
    pub version: u32,
    pub statements: &'static [&'static str],
}

pub trait EncryptedDatabase: fmt::Debug {
    fn encryption_ready(&self) -> Result<bool, StorageError>;
    fn schema_version(&self) -> Result<u32, StorageError>;
    fn begin_immediate(&mut self) -> Result<(), StorageError>;
    fn execute(&mut self, statement: &str) -> Result<(), StorageError>;
    fn set_schema_version(&mut self, version: u32) -> Result<(), StorageError>;
    fn commit(&mut self) -> Result<(), StorageError>;
    fn rollback(&mut self) -> Result<(), StorageError>;
}

pub trait EncryptedDatabaseFactory {
    type Database: EncryptedDatabase;

    fn open(&self, database_path: &str, key: &[u8]) -> Result<Self::Database, StorageError>;
}

pub struct SqlCipherDatabase {
    connection: Connection,
    transaction_active: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredEvidenceRecord {
    pub source_id: String,
    pub source_url: String,
    pub title: String,
    pub excerpt: String,
    pub untrusted: bool,
}

const CORE_SCHEMA: &[&str] = &[
    "CREATE TABLE characters (id TEXT PRIMARY KEY NOT NULL, alias TEXT NOT NULL, voice_asset_id TEXT)",
    "CREATE TABLE voice_assets (id TEXT PRIMARY KEY NOT NULL, character_id TEXT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, encrypted_path TEXT NOT NULL, wrapped_key_ref TEXT NOT NULL)",
    "CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, character_id TEXT NOT NULL REFERENCES characters(id) ON DELETE CASCADE, age_band TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER)",
    "CREATE TABLE turns (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, child_text TEXT NOT NULL, character_text TEXT NOT NULL, completed_at INTEGER NOT NULL)",
    "CREATE INDEX turns_session_completed ON turns(session_id, completed_at)",
    "CREATE TABLE deletion_journal (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), character_id TEXT NOT NULL, phase TEXT NOT NULL)",
];
const EVIDENCE_CACHE_SCHEMA: &[&str] = &[
    "CREATE TABLE evidence_cache (cache_key TEXT NOT NULL, ordinal INTEGER NOT NULL, source_id TEXT NOT NULL, source_url TEXT NOT NULL, title TEXT NOT NULL, excerpt TEXT NOT NULL, untrusted INTEGER NOT NULL, expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(cache_key, ordinal))",
    "CREATE INDEX evidence_cache_expiry ON evidence_cache(expires_at)",
    "CREATE INDEX evidence_cache_created ON evidence_cache(created_at)",
];
const SETTINGS_AND_PROFILE_SCHEMA: &[&str] = &[
    "CREATE TABLE settings (setting_key TEXT PRIMARY KEY NOT NULL, setting_value TEXT NOT NULL)",
    "ALTER TABLE characters ADD COLUMN traits_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE characters ADD COLUMN parent_guidance TEXT",
    "ALTER TABLE characters ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1",
];

pub const APPLICATION_MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        statements: CORE_SCHEMA,
    },
    Migration {
        version: 2,
        statements: EVIDENCE_CACHE_SCHEMA,
    },
    Migration {
        version: 3,
        statements: SETTINGS_AND_PROFILE_SCHEMA,
    },
];

impl fmt::Debug for SqlCipherDatabase {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SqlCipherDatabase")
            .field("transaction_active", &self.transaction_active)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SqlCipherFactory;

impl EncryptedDatabaseFactory for SqlCipherFactory {
    type Database = SqlCipherDatabase;

    fn open(&self, database_path: &str, key: &[u8]) -> Result<Self::Database, StorageError> {
        if database_path.is_empty() || key.len() < 32 {
            return Err(StorageError::VaultUnavailable);
        }
        let connection = Connection::open_with_flags(
            database_path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|_| StorageError::EncryptionUnavailable)?;
        connection
            .pragma_update(None, "key", format!("x'{}'", hex::encode(key)))
            .map_err(|_| StorageError::EncryptionUnavailable)?;
        connection
            .pragma_update(None, "cipher_memory_security", "ON")
            .map_err(|_| StorageError::EncryptionUnavailable)?;
        connection
            .pragma_update(None, "foreign_keys", "ON")
            .map_err(|_| StorageError::EncryptionUnavailable)?;
        connection
            .query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))
            .map_err(|_| StorageError::EncryptionUnavailable)?;
        Ok(SqlCipherDatabase {
            connection,
            transaction_active: false,
        })
    }
}

impl EncryptedDatabase for SqlCipherDatabase {
    fn encryption_ready(&self) -> Result<bool, StorageError> {
        let version = self
            .connection
            .query_row("PRAGMA cipher_version", [], |row| row.get::<_, String>(0))
            .map_err(|_| StorageError::EncryptionUnavailable)?;
        Ok(!version.trim().is_empty())
    }

    fn schema_version(&self) -> Result<u32, StorageError> {
        self.connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(|_| StorageError::MigrationFailed)
    }

    fn begin_immediate(&mut self) -> Result<(), StorageError> {
        if self.transaction_active {
            return Err(StorageError::MigrationFailed);
        }
        self.connection
            .execute_batch("BEGIN IMMEDIATE")
            .map_err(|_| StorageError::MigrationFailed)?;
        self.transaction_active = true;
        Ok(())
    }

    fn execute(&mut self, statement: &str) -> Result<(), StorageError> {
        if !self.transaction_active {
            return Err(StorageError::MigrationFailed);
        }
        self.connection
            .execute_batch(statement)
            .map_err(|_| StorageError::MigrationFailed)
    }

    fn set_schema_version(&mut self, version: u32) -> Result<(), StorageError> {
        if !self.transaction_active {
            return Err(StorageError::MigrationFailed);
        }
        self.connection
            .pragma_update(None, "user_version", version)
            .map_err(|_| StorageError::MigrationFailed)
    }

    fn commit(&mut self) -> Result<(), StorageError> {
        if !self.transaction_active {
            return Err(StorageError::MigrationFailed);
        }
        self.connection
            .execute_batch("COMMIT")
            .map_err(|_| StorageError::MigrationFailed)?;
        self.transaction_active = false;
        Ok(())
    }

    fn rollback(&mut self) -> Result<(), StorageError> {
        if !self.transaction_active {
            return Ok(());
        }
        self.connection
            .execute_batch("ROLLBACK")
            .map_err(|_| StorageError::MigrationFailed)?;
        self.transaction_active = false;
        Ok(())
    }
}

impl SqlCipherDatabase {
    pub fn put_setting(&mut self, key: &str, value: &str) -> Result<(), StorageError> {
        if key.is_empty() || key.len() > 80 || value.len() > 4_096 {
            return Err(StorageError::InvalidData);
        }
        self.connection
            .execute(
                "INSERT INTO settings (setting_key, setting_value) VALUES (?1, ?2) ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value",
                params![key, value],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        Ok(())
    }

    pub fn put_settings(&mut self, settings: &[(&str, &str)]) -> Result<(), StorageError> {
        if settings.is_empty()
            || settings
                .iter()
                .any(|(key, value)| key.is_empty() || key.len() > 80 || value.len() > 4_096)
        {
            return Err(StorageError::InvalidData);
        }
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| StorageError::MigrationFailed)?;
        for (key, value) in settings {
            transaction
                .execute(
                    "INSERT INTO settings (setting_key, setting_value) VALUES (?1, ?2) ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value",
                    params![key, value],
                )
                .map_err(|_| StorageError::MigrationFailed)?;
        }
        transaction
            .commit()
            .map_err(|_| StorageError::MigrationFailed)
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>, StorageError> {
        let mut statement = self
            .connection
            .prepare("SELECT setting_value FROM settings WHERE setting_key = ?1")
            .map_err(|_| StorageError::MigrationFailed)?;
        let mut rows = statement
            .query([key])
            .map_err(|_| StorageError::MigrationFailed)?;
        rows.next()
            .map_err(|_| StorageError::MigrationFailed)?
            .map(|row| row.get(0).map_err(|_| StorageError::InvalidData))
            .transpose()
    }

    pub fn put_character(
        &mut self,
        record: &CharacterRecord,
        traits_json: &str,
        parent_guidance: Option<&str>,
        enabled: bool,
    ) -> Result<(), StorageError> {
        if record.id.0.is_empty()
            || record.id.0.len() > 128
            || record.alias.trim().is_empty()
            || record.alias.chars().count() > 80
            || traits_json.len() > 1_024
            || parent_guidance.is_some_and(|value| value.chars().count() > 240)
        {
            return Err(StorageError::InvalidData);
        }
        self.connection
            .execute(
                "INSERT INTO characters (id, alias, voice_asset_id, traits_json, parent_guidance, enabled) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(id) DO UPDATE SET alias = excluded.alias, voice_asset_id = excluded.voice_asset_id, traits_json = excluded.traits_json, parent_guidance = excluded.parent_guidance, enabled = excluded.enabled",
                params![
                    record.id.0,
                    record.alias,
                    record.voice_asset_id.as_ref().map(|id| id.0.as_str()),
                    traits_json,
                    parent_guidance,
                    enabled,
                ],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        Ok(())
    }

    pub fn list_characters(&self) -> Result<Vec<CharacterRecord>, StorageError> {
        let mut statement = self
            .connection
            .prepare("SELECT id, alias, voice_asset_id FROM characters ORDER BY alias, id")
            .map_err(|_| StorageError::MigrationFailed)?;
        let rows = statement
            .query_map([], |row| {
                Ok(CharacterRecord {
                    id: CharacterId(row.get(0)?),
                    alias: row.get(1)?,
                    voice_asset_id: row.get::<_, Option<String>>(2)?.map(VoiceAssetId),
                })
            })
            .map_err(|_| StorageError::MigrationFailed)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|_| StorageError::InvalidData)
    }

    pub fn list_character_profiles(&self) -> Result<Vec<CharacterProfileRecord>, StorageError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, alias, voice_asset_id, traits_json, parent_guidance, enabled FROM characters WHERE enabled = 1 ORDER BY alias, id",
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        let rows = statement
            .query_map([], |row| {
                Ok(CharacterProfileRecord {
                    record: CharacterRecord {
                        id: CharacterId(row.get(0)?),
                        alias: row.get(1)?,
                        voice_asset_id: row.get::<_, Option<String>>(2)?.map(VoiceAssetId),
                    },
                    traits_json: row.get(3)?,
                    parent_guidance: row.get(4)?,
                    enabled: row.get::<_, i64>(5)? == 1,
                })
            })
            .map_err(|_| StorageError::MigrationFailed)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|_| StorageError::InvalidData)
    }

    pub fn delete_character(&mut self, character_id: &CharacterId) -> Result<(), StorageError> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .execute("DELETE FROM turns WHERE session_id IN (SELECT id FROM sessions WHERE character_id = ?1)", [&character_id.0])
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .execute(
                "DELETE FROM sessions WHERE character_id = ?1",
                [&character_id.0],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .execute(
                "DELETE FROM voice_assets WHERE character_id = ?1",
                [&character_id.0],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .execute("DELETE FROM characters WHERE id = ?1", [&character_id.0])
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .commit()
            .map_err(|_| StorageError::MigrationFailed)?;
        Ok(())
    }

    pub fn put_voice(&mut self, record: &VoiceAssetRecord) -> Result<(), StorageError> {
        if record.id.0.is_empty()
            || record.id.0.len() > 128
            || record.character_id.0.is_empty()
            || record.encrypted_path.is_empty()
            || record.encrypted_path.len() > 1_024
            || record.wrapped_key_ref.0.is_empty()
            || record.wrapped_key_ref.0.len() > 256
        {
            return Err(StorageError::InvalidData);
        }
        self.connection
            .execute(
                "INSERT INTO voice_assets (id, character_id, encrypted_path, wrapped_key_ref) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(id) DO UPDATE SET encrypted_path = excluded.encrypted_path, wrapped_key_ref = excluded.wrapped_key_ref",
                params![
                    record.id.0,
                    record.character_id.0,
                    record.encrypted_path,
                    record.wrapped_key_ref.0,
                ],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        self.connection
            .execute(
                "UPDATE characters SET voice_asset_id = ?1 WHERE id = ?2",
                params![record.id.0, record.character_id.0],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        Ok(())
    }

    pub fn get_voice_for_character(
        &self,
        character_id: &CharacterId,
    ) -> Result<Option<VoiceAssetRecord>, StorageError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, character_id, encrypted_path, wrapped_key_ref FROM voice_assets WHERE character_id = ?1 LIMIT 1",
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        let mut rows = statement
            .query([&character_id.0])
            .map_err(|_| StorageError::MigrationFailed)?;
        rows.next()
            .map_err(|_| StorageError::MigrationFailed)?
            .map(|row| {
                Ok(VoiceAssetRecord {
                    id: VoiceAssetId(row.get(0).map_err(|_| StorageError::InvalidData)?),
                    character_id: CharacterId(row.get(1).map_err(|_| StorageError::InvalidData)?),
                    encrypted_path: row.get(2).map_err(|_| StorageError::InvalidData)?,
                    wrapped_key_ref: SecretRef(row.get(3).map_err(|_| StorageError::InvalidData)?),
                })
            })
            .transpose()
    }

    pub fn delete_voice_for_character(
        &mut self,
        character_id: &CharacterId,
    ) -> Result<usize, StorageError> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .execute(
                "UPDATE characters SET voice_asset_id = NULL WHERE id = ?1",
                [&character_id.0],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        let deleted = transaction
            .execute(
                "DELETE FROM voice_assets WHERE character_id = ?1",
                [&character_id.0],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .commit()
            .map_err(|_| StorageError::MigrationFailed)?;
        Ok(deleted)
    }

    pub fn put_session(&mut self, record: &SessionRecord) -> Result<(), StorageError> {
        self.connection
            .execute(
                "INSERT INTO sessions (id, character_id, age_band, started_at, ended_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    record.id.0,
                    record.character_id.0,
                    age_band_text(record.age_band),
                    record.started_at,
                    record.ended_at,
                ],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        Ok(())
    }

    pub fn put_turn(&mut self, record: &TurnRecord) -> Result<(), StorageError> {
        if record.child_text.chars().count() > 600 || record.character_text.chars().count() > 600 {
            return Err(StorageError::InvalidData);
        }
        self.connection
            .execute(
                "INSERT INTO turns (session_id, child_text, character_text, completed_at) VALUES (?1, ?2, ?3, ?4)",
                params![record.session_id.0, record.child_text, record.character_text, record.completed_at],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        Ok(())
    }

    pub fn end_session(
        &mut self,
        session_id: &SessionId,
        ended_at: TimestampSeconds,
        history_policy: HistoryPolicy,
    ) -> Result<(), StorageError> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| StorageError::MigrationFailed)?;
        let updated = transaction
            .execute(
                "UPDATE sessions SET ended_at = ?1 WHERE id = ?2",
                params![ended_at, session_id.0],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        if updated != 1 {
            return Err(StorageError::NotFound);
        }
        if history_policy == HistoryPolicy::SessionOnly {
            transaction
                .execute("DELETE FROM turns WHERE session_id = ?1", [&session_id.0])
                .map_err(|_| StorageError::MigrationFailed)?;
        }
        transaction
            .commit()
            .map_err(|_| StorageError::MigrationFailed)
    }

    pub fn list_history(
        &self,
        maximum_turns: usize,
    ) -> Result<Vec<HistoryTurnRecord>, StorageError> {
        if maximum_turns == 0 || maximum_turns > 500 {
            return Err(StorageError::InvalidData);
        }
        let mut statement = self
            .connection
            .prepare(
                "SELECT child_text, character_text, completed_at FROM turns ORDER BY completed_at DESC, id DESC LIMIT ?1",
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        let rows = statement
            .query_map(
                [i64::try_from(maximum_turns).map_err(|_| StorageError::InvalidData)?],
                |row| {
                    Ok(HistoryTurnRecord {
                        child_text: row.get(0)?,
                        character_text: row.get(1)?,
                        completed_at: row.get(2)?,
                    })
                },
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|_| StorageError::InvalidData)
    }

    pub fn cleanup_expired_history(
        &mut self,
        now: TimestampSeconds,
        retention_days: u16,
    ) -> Result<usize, StorageError> {
        if retention_days == 0 {
            return Err(StorageError::InvalidRetentionDays);
        }
        let cutoff = now.saturating_sub(i64::from(retention_days).saturating_mul(86_400));
        self.connection
            .execute("DELETE FROM turns WHERE completed_at < ?1", [cutoff])
            .map_err(|_| StorageError::MigrationFailed)
    }

    pub fn delete_history(&mut self) -> Result<(), StorageError> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .execute("DELETE FROM turns", [])
            .and_then(|_| transaction.execute("DELETE FROM sessions", []))
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .commit()
            .map_err(|_| StorageError::MigrationFailed)
    }

    pub fn delete_all(&mut self) -> Result<(), StorageError> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| StorageError::MigrationFailed)?;
        for table in [
            "turns",
            "sessions",
            "voice_assets",
            "characters",
            "settings",
            "evidence_cache",
            "deletion_journal",
        ] {
            transaction
                .execute(&format!("DELETE FROM {table}"), [])
                .map_err(|_| StorageError::MigrationFailed)?;
        }
        transaction
            .commit()
            .map_err(|_| StorageError::MigrationFailed)
    }

    pub fn put_evidence(
        &mut self,
        cache_key: &str,
        created_at: TimestampSeconds,
        expires_at: TimestampSeconds,
        records: &[StoredEvidenceRecord],
        maximum_cache_entries: usize,
    ) -> Result<(), StorageError> {
        if cache_key.is_empty()
            || cache_key.len() > 256
            || records.is_empty()
            || records.len() > 8
            || maximum_cache_entries == 0
            || expires_at <= created_at
            || records.iter().any(|record| {
                record.source_id.is_empty()
                    || record.source_id.len() > 256
                    || record.source_url.len() > 2_048
                    || record.title.len() > 512
                    || record.excerpt.len() > 8_192
            })
        {
            return Err(StorageError::InvalidData);
        }
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .execute(
                "DELETE FROM evidence_cache WHERE cache_key = ?1",
                [cache_key],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        for (ordinal, record) in records.iter().enumerate() {
            transaction
                .execute(
                    "INSERT INTO evidence_cache (cache_key, ordinal, source_id, source_url, title, excerpt, untrusted, expires_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                    params![
                        cache_key,
                        i64::try_from(ordinal).map_err(|_| StorageError::InvalidData)?,
                        record.source_id,
                        record.source_url,
                        record.title,
                        record.excerpt,
                        record.untrusted,
                        expires_at,
                        created_at,
                    ],
                )
                .map_err(|_| StorageError::MigrationFailed)?;
        }
        transaction
            .execute(
                "DELETE FROM evidence_cache WHERE cache_key IN (SELECT cache_key FROM evidence_cache GROUP BY cache_key ORDER BY MAX(created_at) DESC, cache_key DESC LIMIT -1 OFFSET ?1)",
                [i64::try_from(maximum_cache_entries).map_err(|_| StorageError::InvalidData)?],
            )
            .map_err(|_| StorageError::MigrationFailed)?;
        transaction
            .commit()
            .map_err(|_| StorageError::MigrationFailed)
    }

    pub fn get_evidence(
        &mut self,
        cache_key: &str,
        now: TimestampSeconds,
    ) -> Result<Option<Vec<StoredEvidenceRecord>>, StorageError> {
        self.connection
            .execute("DELETE FROM evidence_cache WHERE expires_at <= ?1", [now])
            .map_err(|_| StorageError::MigrationFailed)?;
        let mut statement = self
            .connection
            .prepare("SELECT source_id, source_url, title, excerpt, untrusted FROM evidence_cache WHERE cache_key = ?1 ORDER BY ordinal")
            .map_err(|_| StorageError::MigrationFailed)?;
        let rows = statement
            .query_map([cache_key], |row| {
                Ok(StoredEvidenceRecord {
                    source_id: row.get(0)?,
                    source_url: row.get(1)?,
                    title: row.get(2)?,
                    excerpt: row.get(3)?,
                    untrusted: row.get(4)?,
                })
            })
            .map_err(|_| StorageError::MigrationFailed)?;
        let records = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| StorageError::MigrationFailed)?;
        Ok((!records.is_empty()).then_some(records))
    }
}

const fn age_band_text(age_band: AgeBand) -> &'static str {
    match age_band {
        AgeBand::FourToFive => "4-5",
        AgeBand::SixToEight => "6-8",
        AgeBand::NineToTwelve => "9-12",
    }
}

pub fn migrate_database(
    database: &mut impl EncryptedDatabase,
    migrations: &[Migration],
) -> Result<(), StorageError> {
    let current = database.schema_version()?;
    let target = migrations.last().map_or(0, |migration| migration.version);
    if current > target {
        return Err(StorageError::UnsupportedSchema);
    }
    let mut expected = current.saturating_add(1);
    for migration in migrations
        .iter()
        .filter(|migration| migration.version > current)
    {
        if migration.version != expected {
            return Err(StorageError::UnsupportedSchema);
        }
        database.begin_immediate()?;
        let result = migration
            .statements
            .iter()
            .try_for_each(|statement| database.execute(statement))
            .and_then(|()| database.set_schema_version(migration.version))
            .and_then(|()| database.commit());
        if result.is_err() {
            let _ = database.rollback();
            return Err(StorageError::MigrationFailed);
        }
        expected = expected.saturating_add(1);
    }
    Ok(())
}

pub fn open_encrypted_database<F: EncryptedDatabaseFactory>(
    factory: &F,
    vault: &impl KeyVault,
    database_path: &str,
    key_reference: &SecretRef,
    migrations: &[Migration],
) -> Result<F::Database, StorageError> {
    let key = vault
        .load(key_reference)
        .ok_or(StorageError::VaultUnavailable)?;
    if key.expose().len() < 32 {
        return Err(StorageError::VaultUnavailable);
    }
    let mut database = factory.open(database_path, key.expose())?;
    if !database.encryption_ready()? {
        return Err(StorageError::EncryptionUnavailable);
    }
    migrate_database(&mut database, migrations)?;
    Ok(database)
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct InMemoryRepository {
    state: StorageState,
}

impl InMemoryRepository {
    pub fn transaction<T>(
        &mut self,
        operation: impl FnOnce(&mut Self) -> Result<T, StorageError>,
    ) -> Result<T, StorageError> {
        let mut working = self.clone();
        let result = operation(&mut working)?;
        self.state = working.state;
        Ok(result)
    }

    pub fn insert_character(&mut self, record: CharacterRecord) -> Result<(), StorageError> {
        if self.state.characters.contains_key(&record.id) {
            return Err(StorageError::Duplicate);
        }
        self.state.characters.insert(record.id.clone(), record);
        Ok(())
    }

    pub fn insert_voice(&mut self, record: VoiceAssetRecord) -> Result<(), StorageError> {
        if !self.state.characters.contains_key(&record.character_id) {
            return Err(StorageError::NotFound);
        }
        if self.state.voices.contains_key(&record.id) {
            return Err(StorageError::Duplicate);
        }
        self.state.voices.insert(record.id.clone(), record);
        Ok(())
    }

    pub fn insert_session(&mut self, record: SessionRecord) -> Result<(), StorageError> {
        if !self.state.characters.contains_key(&record.character_id) {
            return Err(StorageError::NotFound);
        }
        if self.state.sessions.contains_key(&record.id) {
            return Err(StorageError::Duplicate);
        }
        self.state.sessions.insert(record.id.clone(), record);
        Ok(())
    }

    pub fn insert_turn(&mut self, record: TurnRecord) -> Result<(), StorageError> {
        if !self.state.sessions.contains_key(&record.session_id) {
            return Err(StorageError::NotFound);
        }
        self.state.turns.push(record);
        Ok(())
    }

    pub fn end_session(
        &mut self,
        session_id: &SessionId,
        ended_at: TimestampSeconds,
        history_policy: HistoryPolicy,
    ) -> Result<(), StorageError> {
        let session = self
            .state
            .sessions
            .get_mut(session_id)
            .ok_or(StorageError::NotFound)?;
        session.ended_at = Some(ended_at);
        if history_policy == HistoryPolicy::SessionOnly {
            self.state
                .turns
                .retain(|turn| &turn.session_id != session_id);
        }
        Ok(())
    }

    pub fn cleanup_expired(
        &mut self,
        now: TimestampSeconds,
        history_policy: HistoryPolicy,
    ) -> Result<usize, StorageError> {
        let HistoryPolicy::RetainDays(days) = history_policy else {
            return Ok(0);
        };
        if days == 0 {
            return Err(StorageError::InvalidRetentionDays);
        }
        let cutoff = now.saturating_sub(i64::from(days).saturating_mul(86_400));
        let before = self.state.turns.len();
        self.state.turns.retain(|turn| turn.completed_at >= cutoff);
        Ok(before - self.state.turns.len())
    }

    pub fn external_projection(
        &self,
        session_id: &SessionId,
        maximum_turns: usize,
    ) -> Result<Vec<ExternalTurnProjection>, StorageError> {
        let session = self
            .state
            .sessions
            .get(session_id)
            .ok_or(StorageError::NotFound)?;
        let matching: Vec<_> = self
            .state
            .turns
            .iter()
            .filter(|turn| &turn.session_id == session_id)
            .collect();
        let skip = matching.len().saturating_sub(maximum_turns);
        Ok(matching
            .into_iter()
            .skip(skip)
            .map(|turn| ExternalTurnProjection {
                age_band: session.age_band,
                child_text: turn.child_text.clone(),
                character_text: turn.character_text.clone(),
            })
            .collect())
    }

    pub fn begin_character_deletion(
        &mut self,
        character_id: &CharacterId,
    ) -> Result<(), StorageError> {
        if self.state.deletion.is_some() {
            return Err(StorageError::DeletionAlreadyActive);
        }
        if !self.state.characters.contains_key(character_id) {
            return Err(StorageError::NotFound);
        }
        self.state.deletion = Some(DeletionJournal {
            character_id: character_id.clone(),
            phase: DeletionPhase::DestroyWrappedKeys,
        });
        Ok(())
    }

    pub fn advance_character_deletion(&mut self) -> Result<Option<DeletionJournal>, StorageError> {
        let journal = self.state.deletion.clone().ok_or(StorageError::NotFound)?;
        match journal.phase {
            DeletionPhase::DestroyWrappedKeys => {
                for voice in self
                    .state
                    .voices
                    .values_mut()
                    .filter(|voice| voice.character_id == journal.character_id)
                {
                    voice.wrapped_key_ref.0.clear();
                }
                self.state.deletion = Some(DeletionJournal {
                    character_id: journal.character_id,
                    phase: DeletionPhase::DeleteContent,
                });
            }
            DeletionPhase::DeleteContent => {
                let session_ids: Vec<_> = self
                    .state
                    .sessions
                    .values()
                    .filter(|session| session.character_id == journal.character_id)
                    .map(|session| session.id.clone())
                    .collect();
                self.state
                    .turns
                    .retain(|turn| !session_ids.contains(&turn.session_id));
                self.state
                    .sessions
                    .retain(|_, session| session.character_id != journal.character_id);
                self.state
                    .voices
                    .retain(|_, voice| voice.character_id != journal.character_id);
                self.state.characters.remove(&journal.character_id);
                self.state.deletion = None;
            }
        }
        Ok(self.state.deletion.clone())
    }

    #[must_use]
    pub fn turn_count(&self) -> usize {
        self.state.turns.len()
    }

    #[must_use]
    pub fn contains_character(&self, id: &CharacterId) -> bool {
        self.state.characters.contains_key(id)
    }
}

pub trait KeyVault {
    fn store(&mut self, label: &str, secret: Vec<u8>) -> SecretRef;
    fn delete(&mut self, secret_ref: &SecretRef) -> bool;
    fn contains(&self, secret_ref: &SecretRef) -> bool;
    fn load(&self, secret_ref: &SecretRef) -> Option<SecretMaterial>;
}

#[derive(Default)]
pub struct InMemoryKeyVault {
    next_id: u64,
    secrets: HashMap<SecretRef, Vec<u8>>,
}

impl fmt::Debug for InMemoryKeyVault {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("InMemoryKeyVault")
            .field("secret_count", &self.secrets.len())
            .finish()
    }
}

impl KeyVault for InMemoryKeyVault {
    fn store(&mut self, label: &str, secret: Vec<u8>) -> SecretRef {
        self.next_id = self.next_id.saturating_add(1);
        let reference = SecretRef(format!("{label}-{}", self.next_id));
        self.secrets.insert(reference.clone(), secret);
        reference
    }

    fn delete(&mut self, secret_ref: &SecretRef) -> bool {
        self.secrets.remove(secret_ref).is_some()
    }

    fn contains(&self, secret_ref: &SecretRef) -> bool {
        self.secrets.contains_key(secret_ref)
    }

    fn load(&self, secret_ref: &SecretRef) -> Option<SecretMaterial> {
        self.secrets
            .get(secret_ref)
            .cloned()
            .map(SecretMaterial::new)
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        sync::{Arc, Mutex},
        time::{SystemTime, UNIX_EPOCH},
    };

    use super::*;

    #[derive(Debug, Default)]
    struct FakeDatabaseState {
        version: u32,
        encryption_ready: bool,
        transaction_version: Option<u32>,
        statements: Vec<String>,
        commits: usize,
        rollbacks: usize,
    }

    #[derive(Clone, Debug)]
    struct FakeDatabase(Arc<Mutex<FakeDatabaseState>>);

    impl EncryptedDatabase for FakeDatabase {
        fn encryption_ready(&self) -> Result<bool, StorageError> {
            Ok(self.0.lock().unwrap().encryption_ready)
        }

        fn schema_version(&self) -> Result<u32, StorageError> {
            Ok(self.0.lock().unwrap().version)
        }

        fn begin_immediate(&mut self) -> Result<(), StorageError> {
            let mut state = self.0.lock().unwrap();
            state.transaction_version = Some(state.version);
            Ok(())
        }

        fn execute(&mut self, statement: &str) -> Result<(), StorageError> {
            if statement == "FAIL" {
                return Err(StorageError::InjectedFailure);
            }
            self.0.lock().unwrap().statements.push(statement.to_owned());
            Ok(())
        }

        fn set_schema_version(&mut self, version: u32) -> Result<(), StorageError> {
            self.0.lock().unwrap().version = version;
            Ok(())
        }

        fn commit(&mut self) -> Result<(), StorageError> {
            let mut state = self.0.lock().unwrap();
            state.transaction_version = None;
            state.commits += 1;
            Ok(())
        }

        fn rollback(&mut self) -> Result<(), StorageError> {
            let mut state = self.0.lock().unwrap();
            if let Some(version) = state.transaction_version.take() {
                state.version = version;
            }
            state.rollbacks += 1;
            Ok(())
        }
    }

    #[derive(Debug)]
    struct FakeFactory {
        state: Arc<Mutex<FakeDatabaseState>>,
        observed_key_length: Arc<Mutex<Option<usize>>>,
    }

    impl EncryptedDatabaseFactory for FakeFactory {
        type Database = FakeDatabase;

        fn open(&self, _database_path: &str, key: &[u8]) -> Result<Self::Database, StorageError> {
            *self.observed_key_length.lock().unwrap() = Some(key.len());
            Ok(FakeDatabase(Arc::clone(&self.state)))
        }
    }

    fn fake_database(version: u32, encrypted: bool) -> FakeDatabase {
        FakeDatabase(Arc::new(Mutex::new(FakeDatabaseState {
            version,
            encryption_ready: encrypted,
            ..FakeDatabaseState::default()
        })))
    }

    fn temporary_database_path() -> String {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir()
            .join(format!("plushpal-{nonce}.sqlcipher"))
            .to_string_lossy()
            .into_owned()
    }

    fn seeded_repository() -> InMemoryRepository {
        let mut repository = InMemoryRepository::default();
        let character_id = CharacterId("character-1".to_owned());
        repository
            .insert_character(CharacterRecord {
                id: character_id.clone(),
                alias: "bear".to_owned(),
                voice_asset_id: Some(VoiceAssetId("voice-1".to_owned())),
            })
            .unwrap();
        repository
            .insert_voice(VoiceAssetRecord {
                id: VoiceAssetId("voice-1".to_owned()),
                character_id: character_id.clone(),
                encrypted_path: "opaque.bin".to_owned(),
                wrapped_key_ref: SecretRef("wrapped-1".to_owned()),
            })
            .unwrap();
        repository
            .insert_session(SessionRecord {
                id: SessionId("session-1".to_owned()),
                character_id,
                age_band: AgeBand::SixToEight,
                started_at: 10,
                ended_at: None,
            })
            .unwrap();
        repository
    }

    #[test]
    fn failed_transaction_rolls_back_every_write() {
        let mut repository = InMemoryRepository::default();
        let result = repository.transaction(|working| {
            working.insert_character(CharacterRecord {
                id: CharacterId("temporary".to_owned()),
                alias: "temp".to_owned(),
                voice_asset_id: None,
            })?;
            Err::<(), _>(StorageError::InjectedFailure)
        });
        assert_eq!(result, Err(StorageError::InjectedFailure));
        assert!(!repository.contains_character(&CharacterId("temporary".to_owned())));
    }

    #[test]
    fn session_only_history_is_destroyed_when_session_ends() {
        let mut repository = seeded_repository();
        repository
            .insert_turn(TurnRecord {
                session_id: SessionId("session-1".to_owned()),
                child_text: "hello".to_owned(),
                character_text: "hi".to_owned(),
                completed_at: 20,
            })
            .unwrap();
        repository
            .end_session(
                &SessionId("session-1".to_owned()),
                30,
                HistoryPolicy::SessionOnly,
            )
            .unwrap();
        assert_eq!(repository.turn_count(), 0);
    }

    #[test]
    fn retention_boundary_keeps_cutoff_and_removes_older_turns() {
        let mut repository = seeded_repository();
        for completed_at in [99, 100] {
            repository
                .insert_turn(TurnRecord {
                    session_id: SessionId("session-1".to_owned()),
                    child_text: "question".to_owned(),
                    character_text: "answer".to_owned(),
                    completed_at,
                })
                .unwrap();
        }
        let removed = repository
            .cleanup_expired(86_500, HistoryPolicy::RetainDays(1))
            .unwrap();
        assert_eq!(removed, 1);
        assert_eq!(repository.turn_count(), 1);
    }

    #[test]
    fn interrupted_character_deletion_resumes_idempotently() {
        let mut repository = seeded_repository();
        let id = CharacterId("character-1".to_owned());
        repository.begin_character_deletion(&id).unwrap();
        let journal = repository.advance_character_deletion().unwrap().unwrap();
        assert_eq!(journal.phase, DeletionPhase::DeleteContent);
        assert!(repository.contains_character(&id));
        assert_eq!(repository.advance_character_deletion().unwrap(), None);
        assert!(!repository.contains_character(&id));
        assert_eq!(repository.turn_count(), 0);
    }

    #[test]
    fn external_projection_excludes_local_ids_paths_and_key_references() {
        let mut repository = seeded_repository();
        repository
            .insert_turn(TurnRecord {
                session_id: SessionId("session-1".to_owned()),
                child_text: "why?".to_owned(),
                character_text: "because".to_owned(),
                completed_at: 20,
            })
            .unwrap();
        let projection = repository
            .external_projection(&SessionId("session-1".to_owned()), 1)
            .unwrap();
        let debug = format!("{projection:?}");
        assert!(!debug.contains("session-1"));
        assert!(!debug.contains("opaque.bin"));
        assert!(!debug.contains("wrapped-1"));
    }

    #[test]
    fn key_vault_debug_output_never_contains_secret_bytes() {
        let mut vault = InMemoryKeyVault::default();
        let secret = b"super-secret-provider-key".to_vec();
        let reference = vault.store("provider", secret);
        assert!(vault.contains(&reference));
        assert!(!format!("{vault:?}").contains("super-secret-provider-key"));
        assert!(vault.delete(&reference));
        assert!(!vault.contains(&reference));
    }

    #[test]
    fn migrations_apply_in_order_and_commit_each_version() {
        let mut database = fake_database(0, true);
        migrate_database(
            &mut database,
            &[
                Migration {
                    version: 1,
                    statements: &["CREATE characters"],
                },
                Migration {
                    version: 2,
                    statements: &["CREATE sessions", "CREATE turns"],
                },
            ],
        )
        .unwrap();
        let state = database.0.lock().unwrap();
        assert_eq!(state.version, 2);
        assert_eq!(state.commits, 2);
        assert_eq!(state.statements.len(), 3);
        assert_eq!(state.rollbacks, 0);
    }

    #[test]
    fn failed_migration_rolls_back_and_schema_gaps_fail_closed() {
        let mut database = fake_database(0, true);
        assert_eq!(
            migrate_database(
                &mut database,
                &[Migration {
                    version: 1,
                    statements: &["CREATE characters", "FAIL"],
                }],
            ),
            Err(StorageError::MigrationFailed)
        );
        let state = database.0.lock().unwrap();
        assert_eq!(state.version, 0);
        assert_eq!(state.rollbacks, 1);
        drop(state);

        assert_eq!(
            migrate_database(
                &mut database,
                &[Migration {
                    version: 2,
                    statements: &["CREATE sessions"],
                }],
            ),
            Err(StorageError::UnsupportedSchema)
        );
    }

    #[test]
    fn encrypted_bootstrap_requires_vault_key_and_cipher_support() {
        let state = Arc::new(Mutex::new(FakeDatabaseState {
            encryption_ready: true,
            ..FakeDatabaseState::default()
        }));
        let observed = Arc::new(Mutex::new(None));
        let factory = FakeFactory {
            state: Arc::clone(&state),
            observed_key_length: Arc::clone(&observed),
        };
        let mut vault = InMemoryKeyVault::default();
        let missing = SecretRef("missing".to_owned());
        assert!(matches!(
            open_encrypted_database(&factory, &vault, "private.db", &missing, &[]),
            Err(StorageError::VaultUnavailable)
        ));
        let short = vault.store("database", vec![7; 16]);
        assert!(matches!(
            open_encrypted_database(&factory, &vault, "private.db", &short, &[]),
            Err(StorageError::VaultUnavailable)
        ));
        let key = vault.store("database", vec![9; 32]);
        open_encrypted_database(&factory, &vault, "private.db", &key, &[]).unwrap();
        assert_eq!(*observed.lock().unwrap(), Some(32));

        state.lock().unwrap().encryption_ready = false;
        assert!(matches!(
            open_encrypted_database(&factory, &vault, "private.db", &key, &[]),
            Err(StorageError::EncryptionUnavailable)
        ));
    }

    #[test]
    fn loaded_secret_material_is_redacted() {
        let mut vault = InMemoryKeyVault::default();
        let reference = vault.store("database", b"secret-database-key-material-1234".to_vec());
        let material = vault.load(&reference).unwrap();
        assert!(!format!("{material:?}").contains("secret-database-key"));
        assert_eq!(material.expose().len(), 33);
    }

    #[test]
    fn sqlcipher_file_is_encrypted_migrated_and_rejects_wrong_key() {
        static MIGRATIONS: &[Migration] = &[
            Migration {
                version: 1,
                statements: &[
                    "CREATE TABLE private_records(value TEXT NOT NULL)",
                    "INSERT INTO private_records(value) VALUES('child-private-marker')",
                ],
            },
            Migration {
                version: 2,
                statements: &["CREATE INDEX private_records_value ON private_records(value)"],
            },
        ];
        let path = temporary_database_path();
        let mut vault = InMemoryKeyVault::default();
        let correct = vault.store("database", vec![0xA5; 32]);
        let database =
            open_encrypted_database(&SqlCipherFactory, &vault, &path, &correct, MIGRATIONS)
                .unwrap();
        assert!(database.encryption_ready().unwrap());
        assert_eq!(database.schema_version().unwrap(), 2);
        assert_eq!(
            database
                .connection
                .query_row("SELECT value FROM private_records", [], |row| {
                    row.get::<_, String>(0)
                })
                .unwrap(),
            "child-private-marker"
        );
        drop(database);

        let file = fs::read(&path).unwrap();
        assert!(!file.starts_with(b"SQLite format 3"));
        assert!(!file
            .windows(b"child-private-marker".len())
            .any(|window| window == b"child-private-marker"));

        let wrong = vault.store("database", vec![0x5A; 32]);
        assert!(matches!(
            open_encrypted_database(&SqlCipherFactory, &vault, &path, &wrong, MIGRATIONS),
            Err(StorageError::EncryptionUnavailable)
        ));
        let reopened =
            open_encrypted_database(&SqlCipherFactory, &vault, &path, &correct, MIGRATIONS)
                .unwrap();
        assert_eq!(reopened.schema_version().unwrap(), 2);
        drop(reopened);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn evidence_cache_is_bounded_expires_and_is_encrypted_at_rest() {
        let path = temporary_database_path();
        let mut vault = InMemoryKeyVault::default();
        let key = vault.store("database", vec![0xC3; 32]);
        let mut database = open_encrypted_database(
            &SqlCipherFactory,
            &vault,
            &path,
            &key,
            APPLICATION_MIGRATIONS,
        )
        .unwrap();
        let marker = "https://facts.example/private-evidence-marker";
        let record = StoredEvidenceRecord {
            source_id: "source-1".to_owned(),
            source_url: marker.to_owned(),
            title: "Moon".to_owned(),
            excerpt: "The Moon reflects sunlight.".to_owned(),
            untrusted: true,
        };
        database
            .put_evidence("old", 10, 30, std::slice::from_ref(&record), 1)
            .unwrap();
        database
            .put_evidence("new", 20, 40, std::slice::from_ref(&record), 1)
            .unwrap();
        assert_eq!(database.get_evidence("old", 20).unwrap(), None);
        assert_eq!(
            database.get_evidence("new", 20).unwrap(),
            Some(vec![record])
        );
        assert_eq!(database.get_evidence("new", 40).unwrap(), None);
        drop(database);

        let file = fs::read(&path).unwrap();
        assert!(!file.starts_with(b"SQLite format 3"));
        assert!(!file
            .windows(marker.len())
            .any(|window| window == marker.as_bytes()));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn sqlcipher_profile_history_and_delete_all_round_trip() {
        let path = temporary_database_path();
        let marker = "private-parent-setting-marker";
        let mut vault = InMemoryKeyVault::default();
        let key = vault.store("database", vec![0xD4; 32]);
        let mut database = open_encrypted_database(
            &SqlCipherFactory,
            &vault,
            &path,
            &key,
            APPLICATION_MIGRATIONS,
        )
        .unwrap();
        assert_eq!(database.schema_version().unwrap(), 3);
        database.put_setting("parent_pin_ref", marker).unwrap();
        assert_eq!(
            database.get_setting("parent_pin_ref").unwrap().as_deref(),
            Some(marker)
        );
        let character = CharacterRecord {
            id: CharacterId("character-1".to_owned()),
            alias: "Teddy".to_owned(),
            voice_asset_id: None,
        };
        database
            .put_character(
                &character,
                r#"["gentle","curious"]"#,
                Some("Likes science stories."),
                true,
            )
            .unwrap();
        assert_eq!(database.list_characters().unwrap(), vec![character.clone()]);
        let voice = VoiceAssetRecord {
            id: VoiceAssetId("voice-1".to_owned()),
            character_id: character.id.clone(),
            encrypted_path: "voices/voice-1.enc".to_owned(),
            wrapped_key_ref: SecretRef("vault-voice-1".to_owned()),
        };
        database.put_voice(&voice).unwrap();
        assert_eq!(
            database.get_voice_for_character(&character.id).unwrap(),
            Some(voice)
        );
        assert_eq!(
            database.delete_voice_for_character(&character.id).unwrap(),
            1
        );
        assert_eq!(
            database.get_voice_for_character(&character.id).unwrap(),
            None
        );
        let session = SessionRecord {
            id: SessionId("session-1".to_owned()),
            character_id: character.id,
            age_band: AgeBand::SixToEight,
            started_at: 100,
            ended_at: None,
        };
        database.put_session(&session).unwrap();
        database
            .put_turn(&TurnRecord {
                session_id: session.id.clone(),
                child_text: "Why is the sky blue?".to_owned(),
                character_text: "Sunlight scatters in the air.".to_owned(),
                completed_at: 120,
            })
            .unwrap();
        database
            .end_session(&session.id, 130, HistoryPolicy::SessionOnly)
            .unwrap();
        assert_eq!(
            database
                .connection
                .query_row("SELECT count(*) FROM turns", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
        let retained_session = SessionRecord {
            id: SessionId("session-2".to_owned()),
            character_id: CharacterId("character-1".to_owned()),
            age_band: AgeBand::SixToEight,
            started_at: 200,
            ended_at: None,
        };
        database.put_session(&retained_session).unwrap();
        for (completed_at, child_text) in [(210, "old question"), (900_000, "new question")] {
            database
                .put_turn(&TurnRecord {
                    session_id: retained_session.id.clone(),
                    child_text: child_text.to_owned(),
                    character_text: "answer".to_owned(),
                    completed_at,
                })
                .unwrap();
        }
        assert_eq!(
            database.list_history(10).unwrap()[0].child_text,
            "new question"
        );
        assert_eq!(database.cleanup_expired_history(900_000, 7).unwrap(), 1);
        assert_eq!(database.list_history(10).unwrap().len(), 1);
        database.delete_history().unwrap();
        assert!(database.list_history(10).unwrap().is_empty());
        database.delete_all().unwrap();
        assert!(database.list_characters().unwrap().is_empty());
        assert_eq!(database.get_setting("parent_pin_ref").unwrap(), None);
        drop(database);

        let file = fs::read(&path).unwrap();
        assert!(!file.starts_with(b"SQLite format 3"));
        assert!(!file
            .windows(marker.len())
            .any(|window| window == marker.as_bytes()));
        fs::remove_file(path).unwrap();
    }
}
