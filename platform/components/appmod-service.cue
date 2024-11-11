"appmod-service": {
	alias: ""
	annotations: {}
	attributes: workload: definition: {
		apiVersion: "apps/v1"
		kind:       "Deployment"
	}
	description: "Appmod deployment with canary support"
	labels: {}
	type: "component"
}

template: {

    let previewService = "\(context.name)-preview"
	let ampWorkspaceUrl = "{{args.amp-workspace-url}}"
	let ampWorkspaceRegion = "{{args.amp-workspace-region}}"
	let prometheusTargetQuery = "k8s_container_name=\"\(parameter.image_name)\", k8s_namespace_name=\"\(context.namespace)\""

	output: {
		apiVersion: "argoproj.io/v1alpha1"
		kind:       "Rollout"
		metadata: {
            name: context.name
        } 
		spec: {
			replicas:             parameter.replicas
			revisionHistoryLimit: 2
			selector: matchLabels: app: context.name
			strategy: canary: 
			{ 
				canaryService: previewService
				steps: [
					{
						setWeight: 20
					},
					if parameter.functionalGate != _|_ {
						{
							pause: duration: parameter.functionalGate.pause
						},
					},
					if parameter.functionalGate != _|_ {
						{
							analysis: {
								templates: [
									{
										templateName: "functional-gate-\(context.name)"
									}
								],
								args: [
									{
										name: "service-name",
										value: previewService
									}
								]
							}
						},
					},
					{
						setWeight: 40
					},
					{
						pause: duration: "5s"
					},
					{
						setWeight: 60
					},
					{
						pause: duration: "5s"
					},
					{
						setWeight: 80
					},
					if parameter.performanceGate != _|_ {
						{
							pause: {
								duration: parameter.performanceGate.pause
							}
						}
					},
					if parameter.performanceGate != _|_ {
						{
							analysis: {
								templates: [
									{
										templateName: "performance-gate-\(context.name)"
									}
								],
								args: [
									{
										name: "service-name",
										value: previewService
									}
								]
							}
						}
					},
					if parameter.MetricGate  != _|_ {
						{
							pause: {
								duration: parameter.MetricGate.pause
							}
						}
					}
					if parameter.metrics !=  _|_ {
					{
						analysis: {
							templates: [
								{
									templateName: "metrics-\(context.name)"
								}
							],
							args: [
								{
									name: "service-name"
									value: previewService
								}
							]
						}
					}
					}
				]
			}
			template: {
				metadata: labels: app: context.name
				spec: containers: [{
					image:           parameter.image
					imagePullPolicy: "Always"
					name:            parameter.image_name
					ports: [{
						containerPort: parameter.targetPort
					}]
				}]
				spec: serviceAccountName: parameter.serviceAccount
			}
		}
	}
	outputs: {
        "appmod-service-service": {
            apiVersion: "v1"
            kind:       "Service"
            metadata: name: context.name
            spec: {
				selector: app: context.name
				ports: [{
					port:       parameter.port
					targetPort: parameter.targetPort
	            }]
            }
        },
		"appmod-service-preview": {
            apiVersion: "v1"
            kind:       "Service"
            metadata: name: previewService
            spec: {
				selector: app: context.name
				ports: [{
					port:       parameter.port
					targetPort: parameter.targetPort
				}]
            }
        },
		"amp-workspace-secrets": {
			apiVersion: "external-secrets.io/v1beta1"
			kind:       "ExternalSecret"
			metadata: {
				name:      "amp-workspace-secrets"
				namespace: context.namespace
			}
			spec: {
				secretStoreRef: {
					name: "cluster-secretstore-sm"
					kind: "ClusterSecretStore"
				}
				target: {
					name: "amp-workspace"
					template: type: "Opaque"
				}
				data: [
					{
						secretKey: "amp-workspace-url"
						remoteRef: {
							key: "/platform/amp-workspace"
						}
					},
					{
						secretKey: "amp-workspace-region"
						remoteRef: {
							key: "/platform/amp-region"
						}
					}
				]
			}
		}
		if parameter.metrics != _|_ {
			"success-rate-analysis-template": {
				apiVersion: "argoproj.io/v1alpha1"
				kind:       "AnalysisTemplate"
				metadata: {
					name:      "metrics-\(context.name)"
				}
				spec: {
					args: [{
						name: "amp-workspace-url"
						valueFrom: secretKeyRef: {
							name: "amp-workspace"
							key: "amp-workspace-url"
						}
					}, {
						name: "amp-workspace-region"
						valueFrom: secretKeyRef: {
							name: "amp-workspace"
							key: "amp-workspace-region"
						}
					}]
					metrics: 
					[
						for idx, criteria in parameter.metrics.evaluationCriteria {
							name: "metric[\(idx)]-\(context.name): \(criteria.metric)"
							if criteria.successOrFailCondition == "success" {
								interval: criteria.interval
								count: criteria.count
								successCondition: "result[0] \(criteria.comparisonType) \(criteria.threshold)"
							}
							if criteria.successOrFailCondition == "fail" {
								interval: criteria.interval
								count: criteria.count
								failureCondition: "result[0] \(criteria.comparisonType) \(criteria.threshold)"
							}
							provider: prometheus: {
								address: ampWorkspaceUrl
								query: [
									if criteria.function != _|_ {
										"\(criteria.function)(\(criteria.metric){\(prometheusTargetQuery)})"
									}
									if criteria.function == _|_ {
										"\(criteria.metric){\(prometheusTargetQuery)}"
									}
								][0]
								authentication: sigv4: region: ampWorkspaceRegion
							}
						}
					]
				}
			}
		},
		if parameter.functionalGate != _|_ {
			"appmod-functional-analysis-template": {
				kind: "AnalysisTemplate",
				apiVersion: "argoproj.io/v1alpha1",
				metadata: {
					name: "functional-gate-\(context.name)"
				},
				spec: {
					metrics: [
						{
							"name": "\(context.name)-metrics",
							"provider": {
								"job": {
									"spec": {
										"template": {
											"spec": {
												"containers": [
													{
														"name": "test",
														"image": parameter.functionalGate.image,
														"args": [
															"\(previewService):\(parameter.port)",
															"\(parameter.functionalGate.extraArgs)"
															
														]
													}
												],
												"restartPolicy": "Never"
											}
										},
										"backoffLimit": 0
									}
								}
							}
						}
					]
				}
			}
		}
        if parameter.performanceGate != _|_ {
			"appmod-performance-analysis-template": {
				kind: "AnalysisTemplate",
				apiVersion: "argoproj.io/v1alpha1",
				metadata: {
					name: "performance-gate-\(context.name)"
				},
				spec: {
					metrics: [
						{
							"name": "\(context.name)-metrics",
							"provider": {
								"job": {
									"spec": {
										"template": {
											"spec": {
												"containers": [
													{
														"name": "test",
														"image": parameter.performanceGate.image,
														"args": [
															"\(previewService):\(parameter.port)",
															"\(parameter.functionalGate.extraArgs)"
															
														]
													}
												],
												"restartPolicy": "Never"
											}
										},
										"backoffLimit": 0
									}
								}
							}
						}
					]
				}
			}
		}
    }

	#QualityGate: {
		image: string
		pause: string
		extraArgs: *"" | string 
	}

	#MetricGate: {
		pause: *"1s" | string
		evaluationCriteria:
		[...{
				interval: *"1s" | string
				count: *1 | int
				function?: "sum" | "avg" | "max" | "min" | "count"
				successOrFailCondition: *"success" | "fail"
				metric: string
				comparisonType: *">" | ">=" | "<" | "<=" | "==" | "!="
				threshold: *0 | number
			}]
	}

	parameter: {
        image_name: string
        image: string
        replicas: *3 | int
        port: *80 | int
        targetPort: *8080 | int
		serviceAccount: *"default" | string
		functionalGate?: #QualityGate
		performanceGate?: #QualityGate
		metrics?: #MetricGate
    }
}