scenario(
    stages = [stage("60s", mode="poisson", rate=r, name="r%d" % r) for r in [64, 96, 128, 160, 200, 250]],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
