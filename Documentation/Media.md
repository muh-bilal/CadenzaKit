# Test media provenance

Local test audio/images are synthesized by Swift test fixtures, stored temporarily,
and removed after tests. SDK products bundle no audio/artwork/fonts/icon packs.

The required remote-playback integration streams Samplelib's 3-second synth:
https://samplelib.com/mp3/sample-3s.mp3

Source: https://samplelib.com/sample-mp3.html
License: https://samplelib.com/license.html
The publisher states its content was created wholly for the project and permits
use/modification without restrictions. The test does not redistribute a bundled
copy. This is an external integration dependency; network/server failure is a gate
failure, never a skipped test or evidence that playback passed.

The software distribution license is separate from this media provenance.
