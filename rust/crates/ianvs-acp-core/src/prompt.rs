use std::fs::{self, File, Metadata};
use std::io::{Read, Take};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, AudioContent, BlobResourceContents, ContentBlock, EmbeddedResource,
    EmbeddedResourceResource, ImageContent, ResourceLink, TextContent, TextResourceContents,
};
use base64::Engine as _;

use crate::{PromptAttachmentInput, WorkspaceScope};

const MAX_ATTACHMENT_COUNT: usize = 16;
const MAX_SOURCE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_ENCODED_BYTES: usize = 12 * 1024 * 1024;
const MAX_IMAGE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_AUDIO_BYTES: u64 = 8 * 1024 * 1024;
const MAX_TEXT_BYTES: u64 = 256 * 1024;
const MAX_BINARY_BYTES: u64 = 1024 * 1024;
const MAX_METADATA_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Copy)]
pub(crate) struct PromptSupport {
    image: bool,
    audio: bool,
    embedded_context: bool,
}

impl PromptSupport {
    pub(crate) fn from_agent(capabilities: &AgentCapabilities) -> Self {
        Self {
            image: capabilities.prompt_capabilities.image,
            audio: capabilities.prompt_capabilities.audio,
            embedded_context: capabilities.prompt_capabilities.embedded_context,
        }
    }
}

pub(crate) fn project_prompt_content(
    text: &str,
    memory_context: Option<&str>,
    attachments: &[PromptAttachmentInput],
    scope: &WorkspaceScope,
    support: PromptSupport,
) -> Result<Vec<ContentBlock>, String> {
    if attachments.len() > MAX_ATTACHMENT_COUNT {
        return Err(format!(
            "prompt exceeds the {MAX_ATTACHMENT_COUNT} attachment limit"
        ));
    }
    let mut budget = PromptBudget::default();
    let mut blocks = Vec::with_capacity(attachments.len().saturating_add(2));
    if let Some(memory_context) = memory_context.map(str::trim)
        && !memory_context.is_empty()
    {
        push_required(
            &mut blocks,
            &mut budget,
            ContentBlock::Text(TextContent::new(memory_context)),
        )?;
    }
    if !text.is_empty() || attachments.is_empty() {
        push_required(
            &mut blocks,
            &mut budget,
            ContentBlock::Text(TextContent::new(text)),
        )?;
    }
    for attachment in attachments {
        let attachment = PreparedAttachment::new(attachment, scope)?;
        let preferred = preferred_content(&attachment, support, &mut budget)?;
        if let Some(block) = preferred
            && budget.try_push(&mut blocks, block)?
        {
            continue;
        }
        if attachment.inline_data.is_some() {
            return Err(format!(
                "inline image {} exceeds the encoded prompt budget",
                attachment.name
            ));
        }
        let link = attachment.resource_link();
        if !budget.try_push(&mut blocks, link)? {
            return Err(format!(
                "prompt attachment {} exceeds the encoded prompt budget",
                attachment.name
            ));
        }
    }
    Ok(blocks)
}

fn push_required(
    blocks: &mut Vec<ContentBlock>,
    budget: &mut PromptBudget,
    block: ContentBlock,
) -> Result<(), String> {
    if budget.try_push(blocks, block)? {
        Ok(())
    } else {
        Err("prompt text exceeds the encoded prompt budget".to_string())
    }
}

fn preferred_content(
    attachment: &PreparedAttachment,
    support: PromptSupport,
    budget: &mut PromptBudget,
) -> Result<Option<ContentBlock>, String> {
    if attachment.force_resource_link {
        return Ok(None);
    }
    if let Some(data) = attachment.inline_data.as_ref() {
        if !support.image {
            return Err(format!(
                "agent does not support inline image attachment {}",
                attachment.name
            ));
        }
        if attachment.size > MAX_IMAGE_BYTES || attachment.size > budget.remaining_source() {
            return Err(format!(
                "inline image {} exceeds the image prompt budget",
                attachment.name
            ));
        }
        budget.source_bytes = budget.source_bytes.saturating_add(attachment.size);
        return Ok(Some(ContentBlock::Image(ImageContent::new(
            data.clone(),
            attachment.mime_type.clone().unwrap_or_default(),
        ))));
    }
    if attachment.is_image() {
        if !support.image {
            return Ok(None);
        }
        return read_base64(attachment, MAX_IMAGE_BYTES, budget).map(|data| {
            data.map(|data| {
                ContentBlock::Image(
                    ImageContent::new(data, attachment.mime_type.clone().unwrap_or_default())
                        .uri(attachment.uri.clone()),
                )
            })
        });
    }
    if attachment.is_audio() {
        if !support.audio {
            return Ok(None);
        }
        return read_base64(attachment, MAX_AUDIO_BYTES, budget).map(|data| {
            data.map(|data| {
                ContentBlock::Audio(AudioContent::new(
                    data,
                    attachment.mime_type.clone().unwrap_or_default(),
                ))
            })
        });
    }
    if !support.embedded_context {
        return Ok(None);
    }
    if attachment.is_text() {
        let Some(bytes) = read_bytes(attachment, MAX_TEXT_BYTES, budget)? else {
            return Ok(None);
        };
        let text = String::from_utf8(bytes)
            .map_err(|_| format!("prompt attachment {} is not valid UTF-8", attachment.name))?;
        return Ok(Some(ContentBlock::Resource(EmbeddedResource::new(
            EmbeddedResourceResource::TextResourceContents(
                TextResourceContents::new(
                    text,
                    attachment
                        .uri
                        .clone()
                        .expect("file attachment should always have a URI"),
                )
                .mime_type(attachment.mime_type.clone()),
            ),
        ))));
    }
    let Some(data) = read_base64(attachment, MAX_BINARY_BYTES, budget)? else {
        return Ok(None);
    };
    Ok(Some(ContentBlock::Resource(EmbeddedResource::new(
        EmbeddedResourceResource::BlobResourceContents(
            BlobResourceContents::new(
                data,
                attachment
                    .uri
                    .clone()
                    .expect("file attachment should always have a URI"),
            )
            .mime_type(attachment.mime_type.clone()),
        ),
    ))))
}

fn read_base64(
    attachment: &PreparedAttachment,
    item_limit: u64,
    budget: &mut PromptBudget,
) -> Result<Option<String>, String> {
    read_bytes(attachment, item_limit, budget)
        .map(|bytes| bytes.map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes)))
}

fn read_bytes(
    attachment: &PreparedAttachment,
    item_limit: u64,
    budget: &mut PromptBudget,
) -> Result<Option<Vec<u8>>, String> {
    if attachment.size > item_limit || attachment.size > budget.remaining_source() {
        return Ok(None);
    }
    let path = attachment
        .path
        .as_ref()
        .ok_or_else(|| format!("prompt attachment {} has no file path", attachment.name))?;
    let file = File::open(path)
        .map_err(|error| format!("cannot open prompt attachment {}: {error}", attachment.name))?;
    let metadata = file.metadata().map_err(|error| {
        format!(
            "cannot inspect prompt attachment {}: {error}",
            attachment.name
        )
    })?;
    attachment.ensure_unchanged(&metadata)?;
    let mut bytes = Vec::with_capacity(usize::try_from(attachment.size).unwrap_or(0));
    let mut bounded: Take<File> = file.take(attachment.size.saturating_add(1));
    bounded
        .read_to_end(&mut bytes)
        .map_err(|error| format!("cannot read prompt attachment {}: {error}", attachment.name))?;
    if u64::try_from(bytes.len()).ok() != Some(attachment.size) {
        return Err(format!(
            "prompt attachment {} changed while it was being read",
            attachment.name
        ));
    }
    budget.source_bytes = budget.source_bytes.saturating_add(attachment.size);
    Ok(Some(bytes))
}

struct PromptBudget {
    source_bytes: u64,
    encoded_bytes: usize,
    block_count: usize,
}

impl Default for PromptBudget {
    fn default() -> Self {
        Self {
            source_bytes: 0,
            encoded_bytes: 2,
            block_count: 0,
        }
    }
}

impl PromptBudget {
    fn remaining_source(&self) -> u64 {
        MAX_SOURCE_BYTES.saturating_sub(self.source_bytes)
    }

    fn try_push(
        &mut self,
        blocks: &mut Vec<ContentBlock>,
        block: ContentBlock,
    ) -> Result<bool, String> {
        let block_bytes = serde_json::to_vec(&block)
            .map_err(|error| format!("cannot encode prompt content: {error}"))?
            .len();
        let separator = usize::from(self.block_count > 0);
        let additional = block_bytes.saturating_add(separator);
        if additional > MAX_ENCODED_BYTES.saturating_sub(self.encoded_bytes) {
            return Ok(false);
        }
        self.encoded_bytes = self.encoded_bytes.saturating_add(additional);
        self.block_count = self.block_count.saturating_add(1);
        blocks.push(block);
        Ok(true)
    }
}

struct PreparedAttachment {
    path: Option<PathBuf>,
    name: String,
    mime_type: Option<String>,
    size: u64,
    device: u64,
    inode: u64,
    uri: Option<String>,
    inline_data: Option<String>,
    force_resource_link: bool,
}

impl PreparedAttachment {
    fn new(input: &PromptAttachmentInput, scope: &WorkspaceScope) -> Result<Self, String> {
        validate_metadata(input)?;
        if let Some(data) = input.data.as_ref() {
            let decoded = base64::engine::general_purpose::STANDARD
                .decode(data)
                .map_err(|_| format!("inline image {} is not valid base64", input.name))?;
            if decoded.is_empty()
                || u64::try_from(decoded.len()).unwrap_or(u64::MAX) > MAX_IMAGE_BYTES
            {
                return Err(format!(
                    "inline image {} must be {MAX_IMAGE_BYTES} bytes or smaller",
                    input.name
                ));
            }
            let decoded_size = u64::try_from(decoded.len()).unwrap_or(u64::MAX);
            if input.size.is_some_and(|size| size != decoded_size) {
                return Err(format!(
                    "inline image {} size metadata does not match its data",
                    input.name
                ));
            }
            let mime_type = normalized_mime(input.mime_type.as_deref(), Path::new(&input.name))?;
            if !mime_type
                .as_deref()
                .is_some_and(|value| value.starts_with("image/"))
            {
                return Err(format!(
                    "inline attachment {} must use an image MIME type",
                    input.name
                ));
            }
            return Ok(Self {
                path: None,
                name: input.name.trim().to_string(),
                mime_type,
                size: decoded_size,
                device: 0,
                inode: 0,
                uri: None,
                inline_data: Some(data.clone()),
                force_resource_link: input.force_resource_link,
            });
        }
        let path = if input.user_approved_outside_workspace {
            resolve_user_approved_file(&input.path)?
        } else {
            scope
                .resolve_existing(&input.path)
                .map_err(|error| error.to_string())?
        };
        let metadata = fs::metadata(&path)
            .map_err(|error| format!("cannot inspect prompt attachment {}: {error}", input.name))?;
        if !metadata.is_file() {
            return Err(format!("prompt attachment {} is not a file", input.name));
        }
        if input.size.is_some_and(|size| size != metadata.len()) {
            return Err(format!(
                "prompt attachment {} changed after selection",
                input.name
            ));
        }
        let mime_type = normalized_mime(input.mime_type.as_deref(), &path)?;
        let uri = file_uri(&path);
        Ok(Self {
            path: Some(path),
            name: input.name.trim().to_string(),
            mime_type,
            size: metadata.len(),
            device: metadata.dev(),
            inode: metadata.ino(),
            uri: Some(uri),
            inline_data: None,
            force_resource_link: input.force_resource_link,
        })
    }

    fn ensure_unchanged(&self, metadata: &Metadata) -> Result<(), String> {
        if !metadata.is_file()
            || metadata.len() != self.size
            || metadata.dev() != self.device
            || metadata.ino() != self.inode
        {
            return Err(format!(
                "prompt attachment {} changed after validation",
                self.name
            ));
        }
        Ok(())
    }

    fn is_image(&self) -> bool {
        self.mime_type
            .as_deref()
            .is_some_and(|value| value.starts_with("image/"))
    }

    fn is_audio(&self) -> bool {
        self.mime_type
            .as_deref()
            .is_some_and(|value| value.starts_with("audio/"))
    }

    fn is_text(&self) -> bool {
        let Some(mime_type) = self.mime_type.as_deref() else {
            return self.path.as_deref().is_some_and(text_extension);
        };
        mime_type.starts_with("text/")
            || matches!(
                mime_type,
                "application/json"
                    | "application/javascript"
                    | "application/toml"
                    | "application/xml"
                    | "application/x-yaml"
                    | "application/yaml"
            )
    }

    fn resource_link(&self) -> ContentBlock {
        ContentBlock::ResourceLink(
            ResourceLink::new(
                self.name.clone(),
                self.uri
                    .clone()
                    .expect("file attachment should always have a URI"),
            )
            .mime_type(self.mime_type.clone())
            .size(i64::try_from(self.size).ok()),
        )
    }
}

fn resolve_user_approved_file(path: &str) -> Result<PathBuf, String> {
    let candidate = Path::new(path);
    if !candidate.is_absolute() {
        return Err("user-approved prompt attachment path must be absolute".to_string());
    }
    candidate
        .canonicalize()
        .map_err(|error| format!("cannot resolve user-approved prompt attachment {path}: {error}"))
}

fn validate_metadata(input: &PromptAttachmentInput) -> Result<(), String> {
    let name = input.name.trim();
    let has_path = !input.path.is_empty();
    let has_data = input.data.as_ref().is_some_and(|data| !data.is_empty());
    if has_path == has_data
        || input.path.len() > MAX_METADATA_BYTES
        || input
            .data
            .as_ref()
            .is_some_and(|data| data.len() > MAX_ENCODED_BYTES)
        || name.is_empty()
        || name.len() > MAX_METADATA_BYTES
        || name.chars().any(char::is_control)
    {
        return Err("prompt attachment contains invalid path or name metadata".to_string());
    }
    Ok(())
}

fn normalized_mime(value: Option<&str>, path: &Path) -> Result<Option<String>, String> {
    let inferred = value.map(str::trim).filter(|value| !value.is_empty());
    let value = inferred
        .map(str::to_ascii_lowercase)
        .or_else(|| infer_mime(path));
    let Some(value) = value else {
        return Ok(None);
    };
    if value.len() > 256
        || !value.is_ascii()
        || !value.contains('/')
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte == b' ')
    {
        return Err("prompt attachment contains an invalid MIME type".to_string());
    }
    Ok(Some(value))
}

fn infer_mime(path: &Path) -> Option<String> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    let value = match extension.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "wav" | "wave" => "audio/wav",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "aac" => "audio/aac",
        "flac" => "audio/flac",
        "ogg" => "audio/ogg",
        "opus" => "audio/opus",
        "webm" => "audio/webm",
        "aiff" | "aif" => "audio/aiff",
        "json" => "application/json",
        "js" => "application/javascript",
        "toml" => "application/toml",
        "xml" => "application/xml",
        "yaml" | "yml" => "application/yaml",
        extension if is_text_extension(extension) => "text/plain",
        _ => return None,
    };
    Some(value.to_string())
}

fn text_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| is_text_extension(&value.to_ascii_lowercase()))
}

fn is_text_extension(extension: &str) -> bool {
    matches!(
        extension,
        "c" | "cc"
            | "cpp"
            | "css"
            | "csv"
            | "dart"
            | "go"
            | "h"
            | "html"
            | "java"
            | "kt"
            | "log"
            | "md"
            | "php"
            | "py"
            | "rb"
            | "rs"
            | "sh"
            | "sql"
            | "swift"
            | "ts"
            | "txt"
            | "zsh"
    )
}

fn file_uri(path: &Path) -> String {
    let mut uri = String::from("file://");
    for byte in path.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric() || matches!(*byte, b'/' | b'-' | b'.' | b'_' | b'~') {
            uri.push(char::from(*byte));
        } else {
            use std::fmt::Write as _;
            let _ = write!(uri, "%{byte:02X}");
        }
    }
    uri
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reviewed_memory_is_a_separate_text_block_before_the_user_prompt() {
        let scope = WorkspaceScope::new(
            std::env::current_dir().expect("current directory"),
            std::iter::empty::<&Path>(),
        )
        .expect("workspace scope");
        let blocks = project_prompt_content(
            "What should I run?",
            Some("<agent_memory_context>Use make verify.</agent_memory_context>"),
            &[],
            &scope,
            PromptSupport {
                image: false,
                audio: false,
                embedded_context: false,
            },
        )
        .expect("prompt content");
        let encoded = serde_json::to_value(blocks).expect("serialize prompt blocks");

        assert_eq!(
            encoded[0]["text"],
            "<agent_memory_context>Use make verify.</agent_memory_context>"
        );
        assert_eq!(encoded[1]["text"], "What should I run?");
    }

    #[test]
    fn inline_clipboard_image_is_projected_without_a_workspace_file() {
        let scope = WorkspaceScope::new(
            std::env::current_dir().expect("current directory"),
            std::iter::empty::<&Path>(),
        )
        .expect("workspace scope");
        let data = base64::engine::general_purpose::STANDARD.encode([1_u8, 2, 3]);
        let attachment = PromptAttachmentInput {
            path: String::new(),
            name: "Pasted Image.png".to_string(),
            mime_type: Some("image/png".to_string()),
            size: Some(3),
            data: Some(data.clone()),
            user_approved_outside_workspace: false,
            force_resource_link: false,
        };

        let blocks = project_prompt_content(
            "inspect this",
            None,
            &[attachment],
            &scope,
            PromptSupport {
                image: true,
                audio: false,
                embedded_context: false,
            },
        )
        .expect("inline image prompt");
        let encoded = serde_json::to_value(blocks).expect("serialize prompt blocks");

        assert_eq!(encoded[1]["type"], "image");
        assert_eq!(encoded[1]["data"], data);
        assert_eq!(encoded[1]["mimeType"], "image/png");
    }

    #[test]
    fn inline_clipboard_image_requires_agent_image_support() {
        let scope = WorkspaceScope::new(
            std::env::current_dir().expect("current directory"),
            std::iter::empty::<&Path>(),
        )
        .expect("workspace scope");
        let attachment = PromptAttachmentInput {
            path: String::new(),
            name: "Pasted Image.png".to_string(),
            mime_type: Some("image/png".to_string()),
            size: Some(3),
            data: Some(base64::engine::general_purpose::STANDARD.encode([1_u8, 2, 3])),
            user_approved_outside_workspace: false,
            force_resource_link: false,
        };

        let error = project_prompt_content(
            "",
            None,
            &[attachment],
            &scope,
            PromptSupport {
                image: false,
                audio: false,
                embedded_context: false,
            },
        )
        .expect_err("unsupported inline image");

        assert!(error.contains("does not support inline image"));
    }
}
