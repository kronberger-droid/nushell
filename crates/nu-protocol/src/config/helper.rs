use super::error::ConfigErrors;
use crate::{Record, ShellError, Span, Type, Value};
use std::{
    borrow::Borrow,
    collections::HashMap,
    fmt::{self, Display},
    hash::Hash,
    ops::{Deref, DerefMut},
    str::FromStr,
};

pub(super) struct ConfigPath<'a> {
    components: Vec<&'a str>,
}

impl<'a> ConfigPath<'a> {
    pub fn new() -> Self {
        Self {
            components: vec!["$env.config"],
        }
    }

    pub fn push(&mut self, key: &'a str) -> ConfigPathScope<'_, 'a> {
        self.components.push(key);
        ConfigPathScope { inner: self }
    }
}

impl Display for ConfigPath<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.components.join("."))
    }
}

pub(super) struct ConfigPathScope<'whole, 'part> {
    inner: &'whole mut ConfigPath<'part>,
}

impl Drop for ConfigPathScope<'_, '_> {
    fn drop(&mut self) {
        self.inner.components.pop();
    }
}

impl<'a> Deref for ConfigPathScope<'_, 'a> {
    type Target = ConfigPath<'a>;

    fn deref(&self) -> &Self::Target {
        self.inner
    }
}

impl DerefMut for ConfigPathScope<'_, '_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.inner
    }
}

pub(super) trait UpdateFromValue: Sized {
    fn update<'a>(
        &mut self,
        value: &'a Value,
        path: &mut ConfigPath<'a>,
        errors: &mut ConfigErrors,
    );
}

impl UpdateFromValue for Value {
    fn update(&mut self, value: &Value, _path: &mut ConfigPath, _errors: &mut ConfigErrors) {
        *self = value.clone();
    }
}

impl UpdateFromValue for bool {
    fn update(&mut self, value: &Value, path: &mut ConfigPath, errors: &mut ConfigErrors) {
        if let Ok(val) = value.as_bool() {
            *self = val;
        } else {
            errors.type_mismatch(path, Type::Bool, value);
        }
    }
}

impl UpdateFromValue for i64 {
    fn update(&mut self, value: &Value, path: &mut ConfigPath, errors: &mut ConfigErrors) {
        if let Ok(val) = value.as_int() {
            *self = val;
        } else {
            errors.type_mismatch(path, Type::Int, value);
        }
    }
}

impl UpdateFromValue for usize {
    fn update(&mut self, value: &Value, path: &mut ConfigPath, errors: &mut ConfigErrors) {
        if let Ok(val) = value.as_int() {
            if let Ok(val) = val.try_into() {
                *self = val;
            } else {
                errors.invalid_value(path, "a non-negative integer", value);
            }
        } else {
            errors.type_mismatch(path, Type::Int, value);
        }
    }
}

impl UpdateFromValue for String {
    fn update(&mut self, value: &Value, path: &mut ConfigPath, errors: &mut ConfigErrors) {
        if let Ok(val) = value.as_str() {
            *self = val.into();
        } else {
            errors.type_mismatch(path, Type::String, value);
        }
    }
}

impl<K, V> UpdateFromValue for HashMap<K, V>
where
    K: Borrow<str> + for<'a> From<&'a str> + Eq + Hash,
    V: Default + UpdateFromValue,
{
    fn update<'a>(
        &mut self,
        value: &'a Value,
        path: &mut ConfigPath<'a>,
        errors: &mut ConfigErrors,
    ) {
        if let Ok(record) = value.as_record() {
            *self = record
                .iter()
                .map(|(key, val)| {
                    let mut old = self.remove(key).unwrap_or_default();
                    old.update(val, &mut path.push(key), errors);
                    (key.as_str().into(), old)
                })
                .collect();
        } else {
            errors.type_mismatch(path, Type::record(), value);
        }
    }
}

pub(super) fn config_update_string_enum<T>(
    choice: &mut T,
    value: &Value,
    path: &mut ConfigPath,
    errors: &mut ConfigErrors,
) where
    T: FromStr,
    T::Err: Display,
{
    if let Ok(str) = value.as_str() {
        match str.parse() {
            Ok(val) => *choice = val,
            Err(err) => errors.invalid_value(path, err.to_string(), value),
        }
    } else {
        errors.type_mismatch(path, Type::String, value);
    }
}

/// Collapses entries of an assigned config list that share a key.
///
/// The later entry wins but takes the earlier one's position, so appending a
/// binding that is already in the list (re-sourcing a config that uses `++=`)
/// updates it in place instead of growing the list. Entries with distinct keys
/// keep their order.
pub(super) fn dedup_by_key_last_wins<T, K: PartialEq>(
    items: Vec<T>,
    key: impl Fn(&T) -> K,
) -> Vec<T> {
    let mut kept: Vec<(K, T)> = Vec::with_capacity(items.len());
    for item in items {
        let k = key(&item);
        match kept.iter_mut().find(|(seen, _)| *seen == k) {
            Some((_, slot)) => *slot = item,
            None => kept.push((k, item)),
        }
    }
    kept.into_iter().map(|(_, item)| item).collect()
}

pub fn extract_value<'record>(
    column: &'static str,
    record: &'record Record,
    span: Span,
) -> Result<&'record Value, ShellError> {
    record
        .get(column)
        .ok_or_else(|| ShellError::MissingRequiredColumn { column, span })
}
