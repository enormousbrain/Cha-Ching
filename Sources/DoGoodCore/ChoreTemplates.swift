import Foundation

public enum ChoreTemplateAgeGroup: String, CaseIterable, Identifiable, Sendable {
    case ages5To7
    case ages8To10
    case ages11To12
    case ages13Plus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ages5To7: return "Ages 5–7"
        case .ages8To10: return "Ages 8–10"
        case .ages11To12: return "Ages 11–12"
        case .ages13Plus: return "Ages 13+"
        }
    }

    public var note: String {
        switch self {
        case .ages5To7: return "Simple jobs with an adult nearby"
        case .ages8To10: return "Building independence with check-ins"
        case .ages11To12: return "More complete household responsibilities"
        case .ages13Plus: return "Adapted starting points for teens"
        }
    }
}

public struct ChoreTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    public let ageGroup: ChoreTemplateAgeGroup
    public let title: String
    public let description: String
    public let instructions: String
    public let expectedEvidence: String
    public let dueTime: String
    public let recurrence: ChoreRecurrence
    public let deductionCents: Int

    public init(id: String, ageGroup: ChoreTemplateAgeGroup, title: String, description: String,
                instructions: String, expectedEvidence: String, dueTime: String = "6:00 PM",
                recurrence: ChoreRecurrence = ChoreRecurrence(frequency: .daily), deductionCents: Int = 100) {
        self.id = id
        self.ageGroup = ageGroup
        self.title = title
        self.description = description
        self.instructions = instructions
        self.expectedEvidence = expectedEvidence
        self.dueTime = dueTime
        self.recurrence = recurrence
        self.deductionCents = deductionCents
    }

    public static let all: [ChoreTemplate] = [
        template(.ages5To7, "Put toys away", "Put toys and games back where they belong.", "Put every toy and game in its home and leave the floor clear.", "A photo of the tidy play area.", "7:00 PM"),
        template(.ages5To7, "Make the bed", "Straighten your bed each morning.", "Pull up the sheets, place the pillow at the top, and leave the blanket neat.", "A photo showing the made bed.", "8:00 AM"),
        template(.ages5To7, "Set the table", "Help get mealtime ready.", "Place the napkins, utensils, and safe dishes at each place.", "A photo of the set table.", "5:30 PM"),
        template(.ages5To7, "Put clothes in the hamper", "Keep dirty clothes off the floor.", "Put all dirty clothes and towels in the hamper.", "A photo of the clear floor and hamper.", "7:00 PM"),
        template(.ages5To7, "Fill the pet food dish", "Help care for a family pet.", "With an adult checking the amount, fill the pet's food dish and put the food away.", "A photo of the filled dish.", "6:00 PM"),

        template(.ages8To10, "Vacuum a room", "Keep one room's floor clean.", "Move small items safely, vacuum the floor, and return the items.", "A photo showing the cleaned floor.", "6:30 PM"),
        template(.ages8To10, "Put away laundry", "Take care of your clean clothes.", "Fold or hang your clean clothes and put them in the right drawers or closet.", "A photo of the cleared laundry basket.", "7:00 PM"),
        template(.ages8To10, "Put away groceries", "Help unload and organize groceries.", "Put groceries in their assigned places, asking an adult about anything unfamiliar.", "A photo of the groceries put away.", "6:30 PM"),
        template(.ages8To10, "Make a snack", "Prepare one snack independently.", "Make an agreed-upon snack, clean the work area, and put ingredients away.", "A photo of the finished snack and clean area.", "3:30 PM"),
        template(.ages8To10, "Water plants", "Help care for household plants.", "Check the soil and water the assigned plants without spilling.", "A photo of the cared-for plants.", "5:00 PM"),

        template(.ages11To12, "Unload the dishwasher", "Help reset the kitchen.", "Put clean dishes, utensils, and glasses in their assigned places.", "A photo of the empty dishwasher.", "6:30 PM"),
        template(.ages11To12, "Change bed sheets", "Refresh your bed each week.", "Remove used sheets, place them in the hamper, and make the bed with clean sheets.", "A photo of the refreshed bed.", "11:00 AM", weekly(.saturday)),
        template(.ages11To12, "Clean the bathroom", "Help keep a bathroom ready to use.", "Wipe the sink and counter, clean the mirror, and put supplies away with adult-approved products.", "A photo of the clean sink and counter.", "11:00 AM", weekly(.saturday)),
        template(.ages11To12, "Fold laundry", "Help finish a laundry load.", "Fold the assigned laundry and put it in the correct rooms or drawers.", "A photo of the folded laundry.", "6:30 PM", weekly(.sunday)),
        template(.ages11To12, "Cook a simple meal", "Practice a supervised kitchen skill.", "Prepare an agreed-upon simple meal with an adult supervising heat, knives, and cleanup.", "A photo of the meal and clean workspace.", "6:00 PM", weekly(.sunday)),

        template(.ages13Plus, "Do a load of laundry", "Own a complete laundry cycle.", "Sort, wash, dry, fold, and put away one agreed-upon load, following care labels.", "A photo of the folded laundry put away.", "7:00 PM", weekly(.saturday)),
        template(.ages13Plus, "Clean the kitchen", "Reset the kitchen after the day's meals.", "Clear dishes, wipe counters, clean the sink, and sweep the floor.", "A photo of the clean counters and sink.", "7:30 PM"),
        template(.ages13Plus, "Take out the trash", "Help keep household waste under control.", "Collect assigned bins, tie bags securely, and place them at the approved pickup spot.", "A photo of the bins at the pickup spot.", "8:00 PM"),
        template(.ages13Plus, "Wash the car", "Help care for a family vehicle.", "With an adult-approved setup, wash the exterior and return supplies to storage.", "A photo of the clean vehicle.", "11:00 AM", weekly(.saturday)),
        template(.ages13Plus, "Prepare a family meal", "Plan and prepare one agreed-upon meal.", "Follow the recipe, use kitchen safety rules, serve the meal, and clean the workspace.", "A photo of the meal and clean workspace.", "6:00 PM", weekly(.sunday))
    ]

    public static func forAgeGroup(_ ageGroup: ChoreTemplateAgeGroup) -> [ChoreTemplate] {
        all.filter { $0.ageGroup == ageGroup }
    }

    private static func weekly(_ weekday: ChoreWeekday) -> ChoreRecurrence {
        ChoreRecurrence(frequency: .weekly, weekdays: [weekday])
    }

    private static func template(_ ageGroup: ChoreTemplateAgeGroup, _ title: String, _ description: String,
                                 _ instructions: String, _ evidence: String, _ dueTime: String,
                                 _ recurrence: ChoreRecurrence = ChoreRecurrence(frequency: .daily)) -> ChoreTemplate {
        ChoreTemplate(id: "\(ageGroup.rawValue).\(title)", ageGroup: ageGroup, title: title,
                      description: description, instructions: instructions, expectedEvidence: evidence,
                      dueTime: dueTime, recurrence: recurrence)
    }
}
