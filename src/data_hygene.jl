## Author: Logan Jones

using XLSX, DataFrames, CSV

#    Base population (Data/Raw/Pop/)
#    U.S. Census Bureau, Population Division. Annual Estimates of the
#    Resident Population by Single Year of Age and Sex for Utah:
#    April 1, 2020 to July 1, 2025 (SC-EST2025-SYASEX-49).
#    Release date: June 2026. Downloaded: 2026-10-23
#    https://www.census.gov/data/tables/time-series/demo/popest/2020s-state-detail.html 
## clean population data 

workbook = XLSX.readxlsx("Data/Raw/Pop/popEstimates2020-2025byAgeSex.xlsx")
sheet = workbook[1]
data = sheet[:]

# make table with columns: year, age, sex, population
population = DataFrame(year=Int[], age=Int[], sex=String[], population=Int[])
# ages 0-85+
for i in 7:92
    label = data[i, 1]
    label = replace(label, "." => "") # clean up the label for example "85+" becomes "85"
    label = replace(label, "+" => "")
    age = parse(Int, label) # translate the label into an integer

    for year in 2020:2025
        start = 5 + 3 * (year - 2020) # the first column for each year is 5, 8, 11, 14, ...
        # get sex-specific population counts for this year and age
        males = Int(data[i, start+1])
        females = Int(data[i, start+2])
        # add a row to the population table for each sex
        push!(population, (year, age, "M", males))
        push!(population, (year, age, "F", females))
    end
end

total_males_2025 = 0
for row in eachrow(population)
    if row.year == 2025 && row.sex == "M"
        total_males_2025 = total_males_2025 + row.population
    end
end
println(total_males_2025)

mkpath("Data/Clean")
CSV.write("Data/Clean/population.csv", population)

##   Births by mother's age (Data/Raw/Births/)
#    Centers for Disease Control and Prevention, National Center for
#    Health Statistics. National Vital Statistics System, Natality on
#    CDC WONDER Online Database. Natality records 2016–2024.
#    Accessed: [2026-10-23].
#    https://wonder.cdc.gov/natality-expanded-current.html

raw = CSV.read("Data/Raw/Births/Natality, 2016-2024 expanded.csv", DataFrame;
    missingstring=["", "Not Available", "Not Applicable", "Suppressed"],
    silencewarnings=true)

fertility = DataFrame(year=Int[], age_group=String[], births=Int[], women=Int[])

for row in eachrow(raw)
    if !ismissing(row["Notes"])
        continue
    end
    group = row["Age of Mother 9"]
    if group == "Under 15 years" || group == "50 years and over"
        continue
    end
    if ismissing(row["Female Population"])
        continue
    end
    push!(fertility, (Int(row["Year"]), group, Int(row["Births"]), Int(row["Female Population"])))
end

for row in eachrow(raw)
    if !ismissing(row["Notes"])
        continue
    end
    if row["Age of Mother 9"] != "45-49 years"
        continue
    end
    if row["Year"] < 2020
        continue
    end
    women = 0
    for p in eachrow(population)
        if p.year == row["Year"] && p.sex == "F" && p.age >= 45 && p.age <= 49
            women = women + p.population
        end
    end
    push!(fertility, (Int(row["Year"]), "45-49 years", Int(row["Births"]), women))
end

for row in eachrow(raw)
    if !ismissing(row["Notes"])
        continue
    end
    group = row["Age of Mother 9"]
    if group == "Under 15 years"
        target = "15-19 years"
    elseif group == "50 years and over"
        target = "45-49 years"
    else
        continue
    end
    for f in eachrow(fertility)
        if f.year == row["Year"] && f.age_group == target
            f.births = f.births + row["Births"]
        end
    end
end

fertility.rate = fertility.births ./ fertility.women

println("Fertility rows: ", nrow(fertility))

for y in sort(unique(fertility.year))
    tfr = 0.0
    for f in eachrow(fertility)
        if f.year == y
            tfr = tfr + f.rate * 5
        end
    end
    println(y, "   ", round(tfr, digits=3))
end

CSV.write("Data/Clean/fertility.csv", fertility)

##   Survival rates (Data/Raw/Mortality/)
#    National Center for Health Statistics. U.S. State Life Tables, 2022.
#    National Vital Statistics Reports, Vol. 74, No. 12. Hyattsville, MD:
#    National Center for Health Statistics; 2025. Downloaded: [2026-10-23].
#    https://ftp.cdc.gov/pub/Health_Statistics/NCHS/Publications/NVSR/74-12/

survival = DataFrame(sex=String[], age=Int[], survival=Float64[])

birth_survival = DataFrame(sex=String[], survival=Float64[])

files = [("M", "Data/Raw/Deaths/UTMales.xlsx"), ("F", "Data/Raw/Deaths/UTfemales.xlsx")]

for (sex, file) in files
    lt = XLSX.readxlsx(file)[1][:]

    @assert lt[4, 3] == 100000

    L = zeros(87)
    for age in 0:86
        L[age+1] = lt[age+4, 5]
    end

    T85 = lt[85+4, 6]
    T86 = lt[86+4, 6]

    for age in 0:84
        push!(survival, (sex, age, L[age+2] / L[age+1]))
    end

    push!(survival, (sex, 85, T86 / T85))

    push!(birth_survival, (sex, L[1] / 100000))
end

println("Survival rows: ", nrow(survival))
println("Lowest survival: ", minimum(survival.survival))
println("Highest survival: ", maximum(survival.survival))
println(birth_survival)

CSV.write("Data/Clean/survival.csv", survival)
CSV.write("Data/Clean/birth_survival.csv", birth_survival)

#   Migration
#   Accessed: 2026-10-23
#   https://www.census.gov/data/tables/time-series/demo/popest/2020s-national-total.html

raw = CSV.read("Data/Raw/Migration/NST-EST2025-ALLDATA (1).csv", DataFrame)

utah_row = 0
for i in 1:nrow(raw)
    if raw[i, "NAME"] == "Utah"
        utah_row = i
    end
end
println("Utah is row ", utah_row)

migration = DataFrame(year=Int[], domestic=Int[], international=Int[], net=Int[])

for year in 2021:2025
    domestic = raw[utah_row, "DOMESTICMIG$year"]
    international = raw[utah_row, "INTERNATIONALMIG$year"]
    push!(migration, (year, domestic, international, domestic + international))
end

println(migration)

CSV.write("Data/Clean/migration.csv", migration)

# ============================================================
# MIGRATION BY AGE AND SEX (residual method)
# ============================================================

pop = Dict()
for row in eachrow(population)
    pop[(row.year, row.age, row.sex)] = row.population
end

surv = Dict()
for row in eachrow(survival)
    surv[(row.sex, row.age)] = row.survival
end

bsurv = Dict()
for row in eachrow(birth_survival)
    bsurv[row.sex] = row.survival
end

male_share = 105 / 205

mig_by_age = DataFrame(year=Int[], age=Int[], sex=String[], migrants=Float64[])

for year in 2021:2025
    births = raw[utah_row, "BIRTHS$year"]

    for sex in ["M", "F"]
        if sex == "M"
            share = male_share
        else
            share = 1 - male_share
        end

        expected = births * share * bsurv[sex]
        push!(mig_by_age, (year, 0, sex, pop[(year, 0, sex)] - expected))

        for age in 1:84
            expected = pop[(year - 1, age - 1, sex)] * surv[(sex, age - 1)]
            push!(mig_by_age, (year, age, sex, pop[(year, age, sex)] - expected))
        end

        expected = pop[(year - 1, 84, sex)] * surv[(sex, 84)] +
                   pop[(year - 1, 85, sex)] * surv[(sex, 85)]
        push!(mig_by_age, (year, 85, sex, pop[(year, 85, sex)] - expected))
    end
end

for year in 2021:2025
    total = 0.0
    for row in eachrow(mig_by_age)
        if row.year == year
            total = total + row.migrants
        end
    end
    println(year, "   residual: ", round(Int, total), "   Census: ", raw[utah_row, "NETMIG$year"])
end

grand_total = sum(mig_by_age.migrants)
profile = DataFrame(age=Int[], sex=String[], share=Float64[])

for sex in ["M", "F"]
    for age in 0:85
        total = 0.0
        for row in eachrow(mig_by_age)
            if row.age == age && row.sex == sex
                total = total + row.migrants
            end
        end
        push!(profile, (age, sex, total / grand_total))
    end
end

println("Shares add to: ", sum(profile.share))

CSV.write("Data/Clean/migration_profile.csv", profile)
