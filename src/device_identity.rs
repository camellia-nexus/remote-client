use camellia_remote_protocol::{
    anyhow::Context,
    config::Config,
    crypto::sign,
    serde_json::{json, Value},
    sha2::{Digest, Sha256},
    ResultType,
};
use serde_derive::Deserialize;
use std::time::{SystemTime, UNIX_EPOCH};

const PROOF_VERSION: &str = "camellia-device-proof-v1";
const PROOF_CLOCK_SKEW_SECS: i64 = 30;
const PROOF_MAX_FUTURE_SECS: i64 = 600;

#[derive(Deserialize)]
struct ProofChallenge {
    challenge: String,
    message: String,
    #[serde(default)]
    expires_at: i64,
}

fn proof_from_challenge(
    challenge: ProofChallenge,
    purpose: &str,
    id: &str,
    uuid: &str,
    secret_key: &[u8],
    public_key: &[u8],
    now: i64,
) -> ResultType<Value> {
    if challenge.challenge.is_empty()
        || challenge.challenge.len() > 128
        || challenge.message.len() > 1_024
    {
        camellia_remote_protocol::bail!("Management returned an invalid device proof challenge");
    }
    let fields = challenge.message.split('\n').collect::<Vec<_>>();
    let generation_valid = fields
        .get(5)
        .and_then(|generation| {
            generation
                .parse::<u64>()
                .ok()
                .map(|value| (generation, value))
        })
        .is_some_and(|(generation, value)| value.to_string() == *generation);
    let expires_at_valid = fields
        .get(7)
        .and_then(|expires_at| expires_at.parse::<i64>().ok())
        == Some(challenge.expires_at);
    let public_key_hash = Sha256::digest(public_key)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    if fields.len() != 8
        || fields[0] != PROOF_VERSION
        || fields[1] != purpose
        || fields[2] != challenge.challenge
        || fields[3] != id
        || fields[4] != uuid
        || !generation_valid
        || fields[6] != public_key_hash
        || !expires_at_valid
        || challenge.expires_at < now - PROOF_CLOCK_SKEW_SECS
        || challenge.expires_at > now + PROOF_MAX_FUTURE_SECS
    {
        camellia_remote_protocol::bail!("Management returned a mismatched device proof challenge");
    }
    let secret_key = sign::SecretKey::from_slice(secret_key).ok_or_else(|| {
        camellia_remote_protocol::anyhow::anyhow!("Local device signing key is invalid")
    })?;
    if public_key.len() != sign::PUBLICKEYBYTES || secret_key.public_key().as_ref() != public_key {
        camellia_remote_protocol::bail!("Local device signing key pair is inconsistent");
    }
    let signed = sign::sign(challenge.message.as_bytes(), &secret_key);
    Ok(json!({
        "challenge": challenge.challenge,
        "public_key": crate::encode64(public_key),
        "signature": crate::encode64(&signed[..sign::SIGNATUREBYTES]),
    }))
}

pub fn request_device_proof(
    api_server: &str,
    purpose: &str,
    id: &str,
    uuid: &str,
    bearer: &str,
) -> ResultType<Value> {
    let (secret_key, public_key) = Config::get_key_pair();
    let body = json!({
        "purpose": purpose,
        "id": id,
        "uuid": uuid,
        "pk": crate::encode64(&public_key),
    });
    let header = if bearer.is_empty() {
        String::new()
    } else {
        format!("Authorization: Bearer {}", bearer)
    };
    let response = crate::post_request_sync(
        format!(
            "{}/api/devices/proof-challenge",
            api_server.trim_end_matches('/')
        ),
        body.to_string(),
        &header,
    )?;
    let challenge = match crate::hbbs_http::HbbHttpResponse::<ProofChallenge>::parse(&response)? {
        crate::hbbs_http::HbbHttpResponse::Data(challenge) => challenge,
        crate::hbbs_http::HbbHttpResponse::Error(error) => {
            camellia_remote_protocol::bail!("{}: {}", error.code, error.message)
        }
        _ => {
            camellia_remote_protocol::bail!("Management returned an invalid device proof response")
        }
    };
    let now = i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("System clock is before the Unix epoch")?
            .as_secs(),
    )
    .context("System clock exceeds the supported range")?;
    proof_from_challenge(challenge, purpose, id, uuid, &secret_key, &public_key, now)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_is_signed_by_the_matching_device_key() {
        let (public_key, secret_key) = sign::gen_keypair();
        let public_key_hash = Sha256::digest(public_key.as_ref())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let message = format!(
            "{PROOF_VERSION}\nlogin\nchallenge\n123456789\ndGVzdA==\n0\n{public_key_hash}\n1800000030"
        );
        let proof = proof_from_challenge(
            ProofChallenge {
                challenge: "challenge".to_owned(),
                message: message.clone(),
                expires_at: 1_800_000_030,
            },
            "login",
            "123456789",
            "dGVzdA==",
            secret_key.as_ref(),
            public_key.as_ref(),
            1_800_000_000,
        )
        .unwrap();
        let signature = crate::decode64(proof["signature"].as_str().unwrap()).unwrap();
        let mut signed = signature;
        signed.extend_from_slice(message.as_bytes());
        assert_eq!(
            sign::verify(&signed, &public_key).unwrap(),
            message.as_bytes()
        );
    }

    #[test]
    fn challenge_signing_rejects_a_management_message_substitution() {
        let (public_key, secret_key) = sign::gen_keypair();
        let result = proof_from_challenge(
            ProofChallenge {
                challenge: "challenge".to_owned(),
                message: "attacker-controlled-message".to_owned(),
                expires_at: 1_800_000_030,
            },
            "login",
            "123456789",
            "dGVzdA==",
            secret_key.as_ref(),
            public_key.as_ref(),
            1_800_000_000,
        );

        assert!(result.is_err());
    }
}
