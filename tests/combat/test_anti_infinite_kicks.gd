extends "res://tests/combat/test_anti_infinite.gd"
## Round 3 anti-infinite, kick patterns: K mashed and P/K alternated at 8 Hz
## (stick neutral) through the real PlayerController against each archetype.

func run() -> void:
	for pattern: String in ["K", "PK"]:
		for arch: StringName in [&"grunt", &"brawler", &"brute", &"duelist"]:
			await start_duel(arch)
			await mash(pattern, SECONDS)
			_report(pattern, arch)
