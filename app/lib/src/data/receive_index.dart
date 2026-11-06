/// How far past the last used address a scan looks, on both chains: the kit's Bitcoin scan, the
/// Sequentia scan and the leaf wallet's own each read in batches of 20 past the last key with
/// history, so an address handed out more than 20 past it would not be found after a restore.
const receiveGap = 20;

/// The receive index a new code moves to (the web wallet's and Ambra browser's rule): the next
/// address after the one [shown], never one below [nextUnused] (the first address no scan has
/// seen used), and never [gap] or more past it, where a restore would not look: past that, back to
/// [nextUnused]. Every address handed out stays one a scan from the phrase alone finds.
int nextReceiveIndex(int shown, int nextUnused, {int gap = receiveGap}) {
  final candidate = shown + 1 > nextUnused ? shown + 1 : nextUnused;
  return candidate >= nextUnused + gap ? nextUnused : candidate;
}

/// The index a kept code's address may be shown at again: [kept] while it is within the window
/// [nextUnused] .. [nextUnused] + [gap] - 1, else [nextUnused].
int keptReceiveIndex(int? kept, int nextUnused, {int gap = receiveGap}) =>
    kept != null && kept >= nextUnused && kept < nextUnused + gap ? kept : nextUnused;
