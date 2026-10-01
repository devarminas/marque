set(MARQUE_FUZZ_NS_wire marque::wire)
set(MARQUE_FUZZ_NS_probe marque::wire::probe)

foreach(schema wire probe)
    foreach(channel state events input intents)
        set(target fuzz_${schema}_${channel})
        add_executable(${target} decoder_fuzz.cpp)
        target_link_libraries(${target} PRIVATE marque_core)
        target_compile_options(${target} PRIVATE -Wall -Wextra -Werror)
        target_compile_definitions(${target} PRIVATE
            MARQUE_FUZZ_NS=${MARQUE_FUZZ_NS_${schema}}
            MARQUE_FUZZ_CHANNEL=${channel})
        target_link_options(${target} PRIVATE -fsanitize=fuzzer)
    endforeach()
endforeach()
