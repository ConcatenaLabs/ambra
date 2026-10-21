//! Issuing and reissuing an asset, as the app builds them on any Sequentia
//! chain. `api` wraps these for the testnet.
//!
//! Sequentia is transparent by default: the issued amount, the asset and its
//! reissuance token go to this wallet's own addresses as explicit outputs, as
//! a send does. Confidentiality is the holder's choice for a later transfer.
//! A reissuance spends the token from its explicit output; the kit then marks
//! the input as a reissuance with the node's sentinel nonce
//! (`ReissuanceExplicitTokenNonce`), since an explicit token has no blinding
//! factor to put there.

use lwk_wollet::elements::{Address, AssetId};
use lwk_wollet::{Network, TxBuilder, Wollet};

/// An address of this wallet at `index` (the next unused one when `None`),
/// in its explicit form.
fn explicit_address(wollet: &Wollet, index: Option<u32>) -> Result<(Address, u32), String> {
    let a = wollet.address(index).map_err(|e| e.to_string())?;
    Ok((a.address().to_unconfidential(), a.index()))
}

/// `asset_sats` of a new asset and `token_sats` of its reissuance token, each
/// to an address of this wallet, explicit.
pub fn issue_builder(
    network: Network,
    wollet: &Wollet,
    asset_sats: u64,
    token_sats: u64,
) -> Result<TxBuilder, String> {
    let (asset_to, index) = explicit_address(wollet, None)?;
    let (token_to, _) = explicit_address(wollet, Some(index + 1))?;
    TxBuilder::new(network)
        .issue_asset(asset_sats, Some(asset_to), token_sats, Some(token_to), None)
        .map_err(|e| e.to_string())
}

/// `satoshi` more of `asset`, whose reissuance token this wallet holds, to an
/// address of this wallet, explicit.
pub fn reissue_builder(
    network: Network,
    wollet: &Wollet,
    asset: AssetId,
    satoshi: u64,
) -> Result<TxBuilder, String> {
    let (to, _) = explicit_address(wollet, None)?;
    TxBuilder::new(network)
        .reissue_asset(asset, satoshi, Some(to), None)
        .map_err(|e| e.to_string())
}
