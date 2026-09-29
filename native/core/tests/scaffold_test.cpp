#include "marque/scaffold.hpp"

#include "check.hpp"

int main() {
    using marque::test::check;

    check(marque::scaffold::answer() == 42, "scaffold::answer returns 42");

    return marque::test::check_finish();
}
