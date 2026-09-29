#pragma once

// Proves the build/test scaffold wires together: marque_core compiles,
// links into a test executable, and ctest picks it up. Later units may
// delete this once real marque_core code exists to test instead.

namespace marque::scaffold {

int answer();

}
