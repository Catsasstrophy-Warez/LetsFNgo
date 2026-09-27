import Foundation
import NexusTrainingData

// Training-data factory, evaluator and promotion gate for Nexus's local
// models (docs/BUILD_PLAN.md §F3, docs/TRAINING_DATA.md). All logic lives in
// NexusTrainingData; this only forwards the arguments and the exit code.
exit(DatasetCommand.run(Array(CommandLine.arguments.dropFirst())))
