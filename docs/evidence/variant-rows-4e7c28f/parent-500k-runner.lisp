(require :asdf)
(asdf:load-system :clamsara/quality/model-resources/test)
(clamsara.quality.model-resources:run-model-resource-array-stress :element-count 500000)
