scenario(
    stages = [stage("45s", mode="poisson", rate=r, name="r%d" % r) for r in [40, 80, 100, 120, 140, 160]],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
