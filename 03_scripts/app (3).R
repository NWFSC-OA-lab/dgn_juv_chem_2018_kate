############
#spec analysis app

library(ggplot2)
library(dplyr)
library(readxl)
library(seacarb)
library(shiny)
library(tidyr)

options(shiny.maxRequestSize=50*1024^2) 

# salinity to alkalinity function
# parametes based on analysis for Trigg et al. paper
# salinity in psu
# alkalinity returned is umol/kg
alkCalc <- function(salinity){
  alk <- 522.506 + 50.345 * salinity
  return(alk)
}

# Define UI ----
ui <- fluidPage(
  titlePanel("Spec pH Analysis"),
  sidebarLayout(
    sidebarPanel( width = 2,
                  fileInput("files", h4("Spec Input Files"), multiple = TRUE, accept = c(".xls", ".xlsx")),
                  fileInput("treatmentfile", h4("Treatment File"), multiple = FALSE, accept = c(".csv")),
                  fileInput("tankfile", h4("Tank File"), multiple = FALSE, accept = c(".csv")),
                  radioButtons("graphType", h4("Graph Type"), 
                               choices = c("Time Series", "Boxplot")),
                  htmlOutput("experiment_selector"),
                  checkboxGroupInput("colourBy", h4("Colour By"), 
                                     choices = c("None", "Unit", "ID_1", "ID_2", "ID_3", "Treatment"),
                                     selected = "None"),
                  radioButtons("facetBy", h4("Facet By"), 
                                     choices = c("None", "Unit", "ID_1", "ID_2","ID_3", "Treatment"),
                                     selected = "None"),
                  uiOutput("unitInclude"),
                  uiOutput("ID1include"),
                  uiOutput("ID2include"),
                  uiOutput("ID3include"),
                  uiOutput("treatInclude"),
                  sliderInput("ySlider", "Y-axis Range)", 
                               min = 6, max = 9, value = c(7, 8.4), step = 0.1),
                  checkboxInput("yRangeCheckbox", "Limit Graph Y-axixs Range", value = FALSE),
                  dateRangeInput("dates", h4("Date range"), start = "2018-03-13"),
                  downloadButton("downloadData", "Download")
    ),
    mainPanel(
      width = 10,
      # this suppresses error messages
      tags$style(type="text/css",
                 ".shiny-output-error { visibility: hidden; }",
                 ".shiny-output-error:before { visibility: hidden; }"
      ),
      plotOutput("plot", width = "100%", height = "740px")
    )
  )
)

# Define server logic ----
server <- function(input, output) {
  values <- reactiveValues(specData = NULL, treatData = NULL, tankData = NULL)
  
  ################
  #read in spec data files
  # combines all the spec files into a single data set
  values$specData <- observeEvent(input$files, {
    
    # d <- data.frame(id_1 = character(0), id_2 = character(0), date  = character(0),
    #                 salinity = character(0), pHat25 = character(0), 
    #                 fileName = character(0), stringsAsFactors = FALSE)
    d <- NULL
    for(i in 1:length(input$files$name)){
      # Set the progress bar, and update the detail text.
      dTemp <- read_excel(input$files$datapath[i], sheet = "pH sheet", skip = 1, col_types = "text")
      if(names(dTemp)[8] == "Date"){
        dTemp1 <- dTemp[!is.na(dTemp[,2]), 2:6]
        dTemp1$id_3 <- NA
        dTemp2 <- dTemp[!is.na(dTemp[,2]), c(7, 8, 10, 12)]
        dTemp <- cbind(dTemp1, dTemp2)
        names(dTemp) <- c("experiment", "unit", "unit_number", "id_1", "id_2", "id_3", "time", "date", 
                          "salinity", "pHat25")
      }
      if(names(dTemp)[8] == "Time Collected"){
        dTemp <- dTemp[!is.na(dTemp[,2]), c(2:9, 11, 13)]
        names(dTemp) <- c("experiment", "unit", "unit_number", "id_1", "id_2","id_3", "time", "date", 
                          "salinity", "pHat25")
      }
      dTemp <- subset(dTemp, !is.na(pHat25))
      dTemp$fileName <- input$files$name[i]
      d <- rbind(d, dTemp)
    }
    #create unit_ID
    d$unit_ID <- paste(d$unit, d$unit_number, sep = "_")
      
    #turn appropriate columns into numeric that shouldn't be labeled as character
    d$salinity <- as.numeric(d$salinity)
    d$pHat25 <- as.numeric(d$pHat25)
    
    #calculate alkalinity
    d$alk <- alkCalc(d$salinity)
    
    d$insituTemp <- NA
    d$pHinsitu <- NA
    
    #function to turn date to a Date
    d$date <- as.Date(as.numeric(d$date), origin = "1899-12-30")
    d$dateString <- as.character(d$date)
    values$specData <- d
  })
  ################
  #read in treatment file
  values$treatData <- observeEvent(input$treatmentfile, {
    
    dt <- read.csv(input$treatmentfile$datapath, header = TRUE, stringsAsFactors = FALSE)
    #convert start and end dates to date objects
    dt$StartDate <- as.Date(dt$StartDate, "%m/%d/%y")
    dt$EndDate <- as.Date(dt$EndDate, "%m/%d/%y")
    values$treatData <- dt
    
    #add the treatment data to the spec data file
    # match based on tank/chamber number and dates
    d <- values$specData
    d$treatName <- ""
    d$treatpH <- NA
    d$treatTemp <- NA
    d$treatOther <- ""
    for(i in 1:length(d$experiment)){
      for(j in 1:length(dt$Unit)){
        if(d$unit[i] == dt$Unit[j] && d$unit_number[i] == dt$UnitNumber[j] &&
           d$date[i] >= dt$StartDate[j]  && d$date[i] <= dt$EndDate[j]
           ){
          d$treatName[i] <- dt$TreatmentName[j]
          d$treatpH[i] <- dt$pH[j]
          d$treatTemp[i] <- dt$Tempereture[j]
          d$treatOther[i] <- dt$AdditionalTreatmentA[j]
        }
      }
      if(d$unit[i] != "Tank"){
        d$insituTemp[i] <- d$treatTemp[i]
      }
    }
    d$insituTemp <- as.numeric(d$insituTemp)
    #calc DIC in umol/kg
    d$dic <- carb(flag = 8, d$pHat25, d$alk/1000000, T = 25, S = d$salinity)$DIC * 1000000
    #get logical vector of rows with data to calc in situ pH
    isOK <- !is.na(d$alk) & !is.na(d$dic) & !is.na(d$insituTemp) & !is.na(d$salinity)
    #calc insitu pH
    d$pHinsitu[isOK] <- carb(flag = 15, d$alk[isOK]/1000000, d$dic[isOK]/1000000, T = d$insituTemp[isOK], S = d$salinity[isOK])$pH
    values$specData <- d
  })
  
  ################
  #read in tank data file
  values$tankData <- observeEvent(input$tankfile, {

    dtank <- read.csv(input$tankfile$datapath, header = TRUE, stringsAsFactors = FALSE)
    dtank$Date <- as.Date(dtank$Date, "%m/%d/%Y")
    
    #fills in tank 1 temperature data for tanks 3 and 5 sinace 3 and 5 do not have uda's 
    dtank$T3.temp <- as.numeric(dtank$T3.temp)
    dtank$T5.temp <- as.numeric(dtank$T5.temp)
    dtank$T3.temp[is.na(dtank$T3.temp)] <- dtank$T1.temp[is.na(dtank$T3.temp)]
    dtank$T5.temp[is.na(dtank$T5.temp)] <- dtank$T1.temp[is.na(dtank$T5.temp)]
    
    #reorganize the data frame to "long skinny" so that it has columns for date, tank and temperature
    dtank <- gather(dtank, key =  tank, value = temperature, T1.temp, T2.temp, T3.temp, T4.temp, T5.temp, T6.temp)
    dtank$tank <-substring(dtank$tank, 2,2)
    dtank <- subset(dtank, select = c("Date", "tank", "temperature"))
    values$tankData <- dtank
    
    d <- values$specData
    d$tankTemp <- NA
    
    # Create a Progress object
    progress <- shiny::Progress$new(min = 1, max = length(d$experiment))
    # Make sure it closes when we exit this reactive, even if there's an error
    on.exit(progress$close())
    
    progress$set(message = "Processing Row", value = 0)

    for(i in 1:length(d$experiment)){
      progress$set(value = i, detail = paste(i, " of ", length(d$experiment)))
      for(j in 1:length(dtank$Date)){
        if(d$date[i] == dtank$Date[j]  && d$unit[i] == "Tank" && d$unit_number[i] == dtank$tank[j]){                            
          d$tankTemp[i] <- dtank$temperature[j]
          d$insituTemp[i] <- d$tankTemp[i]
        }
      }
    }

    d$insituTemp <- as.numeric(d$insituTemp)
    #calc DIC in umol/kg
    d$dic <- carb(flag = 8, d$pHat25, d$alk/1000000, T = 25, S = d$salinity)$DIC * 1000000
    #get logical vector of rows with data to calc in situ pH
    isOK <- !is.na(d$alk) & !is.na(d$dic) & !is.na(d$insituTemp) & !is.na(d$salinity)
    #calc insitu pH
    d$pHinsitu[isOK] <- carb(flag = 15, d$alk[isOK]/1000000, d$dic[isOK]/1000000, T = d$insituTemp[isOK], S = d$salinity[isOK])$pH
    values$specData <- d
  })
  
  ################
  #dynamic inputs
  
  #dynamic drop down list for experiment
  output$experiment_selector = renderUI({ #creates State select box object called in ui
    selectInput(inputId = "experiment", #name of input
                label = "Experiment:", #label displayed in ui
                choices = as.character(unique(values$specData$experiment))) 
  })
  
  #Unit include dynamic checkboxes
  output$unitInclude <- renderUI({
    d <- subset(values$specData, experiment == input$experiment)
    unitsIn <- as.character(unique(d$unit_ID))
    checkboxGroupInput("units", "Include Units", unitsIn, selected = unitsIn)
  })

  #ID1 include dynamic checkboxes
  output$ID1include <- renderUI({
    d <- subset(values$specData, experiment == input$experiment)
    id1 <- as.character(unique(d$id_1))
    checkboxGroupInput("id1", "Include ID_1", id1, selected = id1)
  })

  #ID2 include dynamic checkboxes
  output$ID2include <- renderUI({
    d <- subset(values$specData, experiment == input$experiment)
    id2 <- as.character(unique(d$id_2))
    checkboxGroupInput("id2", "Include ID_2", id2, selected = id2)
  })

  #ID3 include dynamic checkboxes
  output$ID3include <- renderUI({
    d <- subset(values$specData, experiment == input$experiment)
    id3 <- as.character(unique(d$id_3))
    checkboxGroupInput("id3", "Include ID_3", id3, selected = id3)
  })
  
  #Treatment include dynamic checkboxes
  output$treatInclude <- renderUI({
    d <- subset(values$specData, experiment == input$experiment)
    treat <- as.character(unique(d$treatName))
    checkboxGroupInput("treat", "Include Treatment", treat, selected = treat)
  })
  
  output$plot <- renderPlot({
    d <- values$specData
    d <- subset(d, experiment == input$experiment)
    if(!is.null(input$units)){
      d <- subset(d, unit_ID %in% input$units)
    }
    if(!is.null(input$id1) & !(all(input$id1 == ""))){
      d <- subset(d, id_1 %in% input$id1)
    }
    if(!is.null(input$id2) & !(all(input$id2 == ""))){
      d <- subset(d, (id_2 %in% input$id2) | is.na(id_2))
    }
    if(!is.null(input$id3) & !(all(input$id3 == ""))){
      d <- subset(d, (id_3 %in% input$id3) | is.na(id_3))
    }
    if(!is.null(input$treat) & !(all(input$treat == ""))){
      d <- subset(d, (treatName %in% input$treat) | is.na(treatName))
    }

    
    d$colourBy <- "All_Data"
    colourByList <- input$colourBy
    if(colourByList == "None" ){
      d$colourBy <- "All_Data"
    }
    if(colourByList == "Unit" ){
      d$colourBy <- factor(d$unit_ID)
    }
    if(colourByList == "ID_1" ){
      d$colourBy <- factor(d$id_1)
    }
    if(colourByList == "ID_2" ){
      d$colourBy <- factor(d$id_2)
    }
    if(colourByList == "ID_3" ){
      d$colourBy <- factor(d$id_3)
    }
    if(colourByList == "Treatment" ){
      d$colourBy <- factor(d$treatName)
    }
    if(("Unit" %in% colourByList) && ("ID_1" %in% colourByList)){
      d$colourBy <- factor(paste(d$unit_ID, d$id_1, sep = "_"))
    }
    if(("Unit" %in% colourByList) && ("ID_2" %in% colourByList)){
      d$colourBy <- factor(paste(d$unit_ID, d$id_2, sep = "_"))
    }
    if(("Unit" %in% colourByList) && ("Treatment" %in% colourByList)){
      d$colourBy <- factor(paste(d$unit_ID, d$treatName, sep = "_"))
    }
    if(("Unit" %in% colourByList) && ("ID_1" %in% colourByList) &&
       ("ID_2" %in% colourByList)){
      d$colourBy <- factor(paste(d$unit_ID, d$id_1, d$id_2, sep = "_"))
    }
    if(("ID_1" %in% colourByList) && ("Treatment" %in% colourByList)){
      d$colourBy <- factor(paste(d$id_1, d$treatName, sep = "_"))
    }
    if(("ID_3" %in% colourByList) && ("Treatment" %in% colourByList)){
      d$colourBy <- factor(paste(d$id_3, d$treatName, sep = "_"))
    }
    d$facetBy <- ""
    facetByList <- input$facetBy
    if(facetByList == "Unit" ){
      d$facetBy <- factor(d$unit_ID)
    }
    if(facetByList == "ID_1" ){
      d$facetBy <- factor(d$id_1)
    }
    if(facetByList == "ID_2" ){
      d$facetBy <- factor(d$id_2)
    }
    if(facetByList == "Treatment" ){
      d$facetBy <- factor(d$treatName)
    }
    #limit y axis
    yLimits <- c(min(d$pHinsitu), max(d$pHinsitu))
    if(input$yRangeCheckbox){
      yLimits <- c(input$ySlider[1], input$ySlider[2])
    }
    #limit dates
    startGraphDateTime <- as.Date(input$dates[1])
    endGraphDateTime <- as.Date(input$dates[2])
    #add a day to make sure it gets all the way to midnight
    #endGraphDateTime <- endGraphDateTime + 1
    d <- subset(d, date >= startGraphDateTime & date < endGraphDateTime)
    
    gType <- input$graphType
    
    if(gType == "Time Series"){
      p <- ggplot(d, aes_string("date", "pHinsitu")) +
        geom_point(aes(colour = colourBy)) +
        ylim(yLimits) +
     
           ylab("pH at exp. temperature") +
        xlab("Date") +
        theme_bw(base_size = 24)
      if(facetByList != "None"){
        p <- p + facet_wrap( ~ facetBy, ncol = 2)
      }
      return(p)
    }
 
    if(gType == "Boxplot"){
      p <- ggplot(d, aes_string("colourBy", "pHinsitu")) +
        geom_boxplot() +
        geom_jitter(colour = "blue") +
        ylim(yLimits) +
        ylab("pH at exp. temperature") +
        xlab("Group") +
        theme_bw(base_size = 24) +
        theme(axis.text.x = element_text(angle = 90, hjust = 1))
      if(facetByList != "None"){
        p <- p + facet_wrap( ~ facetBy, ncol = 2)
      }
      return(p)
    }
    
  })
  
  # Downloadable csv of selected dataset ----
  output$downloadData <- downloadHandler(
    filename = function() {
      paste("SpecData", ".csv", sep = "")
    },
    content = function(file) {
      write.csv(values$specData, file, row.names = FALSE)
    })
}

# Run the app ----
shinyApp(ui = ui, server = server)





















